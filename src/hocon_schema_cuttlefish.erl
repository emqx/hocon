%%--------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(hocon_schema_cuttlefish).

-ifdef(CUTTLEFISH_CONVERTER).

-export([convert/2]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% @doc convert cuttlefish schema file to hocon schema module.
%% While `mapping` is automatically generated,
%% you have to manually add translations and validators.
%% You also need to set your `roots/0, fields/1` to describe the structure.
-spec convert([string()], string()) -> ok.
convert(SchemaFile, Output) when is_list(SchemaFile) ->
    file:write_file(Output, do_convert(cuttlefish_schema:files([SchemaFile]), Output)).

-spec do_convert(cuttlefish_schema:schema(), string()) -> string().
do_convert({_Translations, Mappings, _Validators}, Output) ->
    ModuleErl = io_lib:format("-module(~s).\n\n", [filename:basename(Output, ".erl")]),
    {PresentTypes, MappingErl} = convert_mapping(Mappings),
    AddedTypes = maps:without(maps:keys(default_types()), PresentTypes),
    TypesErl =
        "-include_lib(\"typerefl/include/types.hrl\").\n\n" ++
            [io_lib:format("-type ~s :: ~s.\n", [K, V]) || {K, V} <- maps:to_list(AddedTypes)],
    Behaviour = "-behaviour(hocon_schema).\n\n",
    ReflectType = io_lib:format(
        "-reflect_type([~s]).\n\n",
        [string:join([string:replace(T, "()", "/0") || T <- maps:keys(AddedTypes)], ", ")]
    ),
    Export = "-export([roots/0, fields/1, translations/0, translation/1]).\n\n",
    lists:flatten([ModuleErl, TypesErl, Behaviour, ReflectType, Export, MappingErl]).

-spec convert_mapping([cuttlefish_mapping:mapping()]) -> {map(), string()}.
convert_mapping(Mappings) ->
    convert_mapping(lists:reverse(Mappings), default_types(), "").

convert_mapping([], PresentTypes, Acc) ->
    {PresentTypes, Acc};
convert_mapping([M | More], PresentTypes, Acc) ->
    Variable = cuttlefish_variable:format(cuttlefish_mapping:variable(M)),
    FuncName = lists:flatten(string:replace(Variable, ".", "__", all)),
    Doc = doc(cuttlefish_mapping:doc(M)),
    MappingClause = mapping(FuncName, cuttlefish_mapping:mapping(M)),
    {TypeClause, NewTypes} = type(FuncName, cuttlefish_mapping:datatype(M), PresentTypes),
    DefaultClause = default(FuncName, cuttlefish_mapping:default(M)),
    ValidatorsClause = validators(FuncName, cuttlefish_mapping:validators(M)),
    OverrideClause = override_env(FuncName, cuttlefish_mapping:override_env(M)),
    WildCardClause = wildcard(FuncName),
    NewAcc = lists:flatten([
        Doc,
        MappingClause,
        TypeClause,
        DefaultClause,
        ValidatorsClause,
        OverrideClause,
        WildCardClause,
        "\n",
        Acc
    ]),
    convert_mapping(More, NewTypes, NewAcc).

doc([]) ->
    "";
doc(Doc) ->
    lists:flatten(io_lib:format("%% @doc ~s~n", [Doc])).

mapping(FuncName, Mapping) ->
    lists:flatten(io_lib:format("~s(mapping) -> ~p;~n", [FuncName, Mapping])).

type(FuncName, Types, PresentTypes) ->
    NewTypes = add_types(Types, PresentTypes),
    GetTypeString = fun
        ({enum, Enum}, _) -> typename_enum(Enum);
        (T, Types) -> maps:get(T, Types)
    end,
    case length(Types) of
        1 ->
            TypeString = GetTypeString(hd(Types), NewTypes),
            {lists:flatten(io_lib:format("~s(type) -> ~s;~n", [FuncName, TypeString])), NewTypes};
        _ ->
            TypeName = typename_union(NewTypes),
            TypeString = string:join([GetTypeString(T, NewTypes) || T <- Types], " | "),
            {lists:flatten(io_lib:format("~s(type) -> ~s;~n", [FuncName, TypeName])), NewTypes#{
                TypeName => TypeString
            }}
    end.

add_types([], PresentTypes) ->
    PresentTypes;
add_types([{enum, Enum} | More], PresentTypes) ->
    TypeName = typename_enum(Enum),
    Union = string:join(lists:map(fun atom_to_list/1, Enum), " | "),
    case maps:get(TypeName, PresentTypes, undefined) of
        undefined ->
            add_types(More, PresentTypes#{TypeName => Union});
        _ ->
            add_types(More, PresentTypes)
    end;
add_types([T | More], PresentTypes) ->
    case maps:get(T, PresentTypes, undefined) of
        undefined ->
            erlang:display(T),
            throw(type_undefined);
        _ ->
            add_types(More, PresentTypes)
    end.

default(_FuncName, undefined) ->
    "";
default(FuncName, Default) ->
    lists:flatten(io_lib:format("~s(default) -> ~p;~n", [FuncName, Default])).

validators(_FuncName, []) ->
    [];
validators(FuncName, Validators) ->
    lists:flatten(io_lib:format("~s(validators) -> ~p;~n", [FuncName, Validators])).

override_env(_FuncName, undefined) ->
    "";
override_env(FuncName, E) ->
    lists:flatten(io_lib:format("~s(override_env) -> ~p;~n", [FuncName, E])).

wildcard(FuncName) ->
    lists:flatten(io_lib:format("~s(_) -> undefined.~n", [FuncName])).

default_types() ->
    #{
        integer => "integer()",
        string => "string()",
        boolean => "boolean()",
        atom => "atom()",
        float => "float()",
        {duration, ms} => "duration()",
        {duration, s} => "duration()",
        {percent, float} => "percent()",
        bytesize => "bytesize()",
        flag => "flag()",
        ip => "typerefl:ip4_address()",
        file => "file()"
    }.

typename_enum(Enum) ->
    "enum_" ++ string:join([atom_to_list(E) || E <- Enum], "_") ++ "()".

typename_union(PresentTypes) ->
    "union_" ++ integer_to_list(maps:size(PresentTypes)) ++ "()".

-ifdef(TEST).

basic_test() ->
    ensure_generated_dir(),
    CuttlefishSchemaFile = "./sample-schemas/cuttlefish_1.schema",
    ConfFile = "etc/cuttlefish-1.conf",
    Dest = "generated/my_module.erl",
    ok = hocon_schema_cuttlefish:convert(CuttlefishSchemaFile, Dest),
    Manual =
        "roots() -> [a].\n"
        "fields(a) ->\n"
        "    [ {b, fun a__b/1}\n"
        "    , {c, fun a__c/1}\n"
        "    , {d, fun a__d/1}\n"
        "    , {e, fun a__e/1}].\n"
        "translations() -> [].\n"
        "translation(_) -> undefined.",
    ok = file:write_file(Dest, Manual, [append]),
    {ok, Conf} = hocon:load(ConfFile, #{format => richmap}),
    {ok, my_module} = compile:file(Dest),
    CuttlefishSchema = cuttlefish_schema:files([CuttlefishSchemaFile]),
    ?assertEqual(
        cuttlefish_generator:map(CuttlefishSchema, cuttlefish_conf:file(ConfFile)),
        hocon_schema:generate(my_module, Conf)
    ),

    {ok, BadConf} = hocon:binary("a.b=aaa", #{format => richmap}),
    ?assertThrow({validation_error, _}, hocon_schema:generate(my_module, BadConf)).

ensure_generated_dir() ->
    _ = os:cmd("rm -Rf " ++ "generated"),
    _ = filelib:ensure_dir("generated/").

-endif.
-endif.
