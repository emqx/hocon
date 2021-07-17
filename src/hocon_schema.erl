%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon_schema).

%% behaviour APIs
-export([ structs/1
        , fields/2
        , translations/1
        , translation/2
        , validations/1
        ]).

-export([map/2, map/3, map/4]).
-export([translate/3]).
-export([generate/2, generate/3, map_translate/3]).
-export([check/2, check/3, check_plain/2, check_plain/3, check_plain/4]).
-export([deep_get/2, deep_get/3, deep_get/4, deep_put/3]).
-export([richmap_to_map/1, get_value/2]).
-export([find_struct/2]).

-include("hoconsc.hrl").

-ifdef(TEST).
-export([nest/1]).
-endif.

-export_type([ name/0
             , typefunc/0
             , translationfunc/0
             , schema/0
             , opts/0
             ]).

-type name() :: atom() | string() | binary().
-type type() :: typerefl:type() %% primitive (or complex, but terminal) type
              | name() %% reference to another struct
              | ?ARRAY(type()) %% array of
              | ?UNION([type()]) %% one-of
              | ?ENUM([atom()]) %% one-of atoms, data is allowed to be binary()
              .

-type typefunc() :: fun((_) -> _).
-type translationfunc() :: fun((hocon:config()) -> hocon:config()).
-type validationfun() :: fun((hocon:config()) -> ok).
-type field_schema() :: typerefl:type()
                      | ?UNION([type()])
                      | ?ARRAY(type())
                      | ?ENUM(type())
                      | #{ type := type()
                         , default => term()
                         , mapping => string()
                         , converter => function()
                         , validator => function()
                         , override_env => string()
                           %% set true if a field is allowed to be `undefined`
                           %% NOTE: has no point setting it to `true` if field has a default value
                         , nullable => boolean() % default = true
                           %% for sensitive data obfuscation (password, token)
                         , sensitive => boolean()
                         }.

-type field() :: {name(), typefunc() | field_schema()}.
-type translation() :: {name(), translationfunc()}.
-type validation() :: {name(), validationfun()}.
-type schema() :: module()
                | #{ structs := [name()]
                   , fileds := #{name() => [field()]}
                   , translations => #{name() => [translation()]} %% for config mappings
                   , validations => [validation()] %% for config integrity checks
                   }.

-define(FROM_ENV_VAR(Name, Value), {'$FROM_ENV_VAR', Name, Value}).
-define(IS_NON_EMPTY_STRING(X), (is_list(X) andalso X =/= [] andalso is_integer(hd(X)))).
-type loggerfunc() :: fun((atom(), map()) -> ok).
-type opts() :: #{ logger => loggerfunc()
                 , atom_key => boolean()
                 , return_plain => boolean()
                   %% By default allow all fields to be undefined.
                   %% if `nullable` is set to `false`
                   %% map or check APIs fail with validation_error.
                   %% NOTE: this option serves as default value for field's `nullable` spec
                 , nullable => boolean() %% default: true for map, false for check

                 %% below options are generated internally and should not be passed in by callers
                 , is_richmap => boolean()
                 , stack => [name()]
                 , schema => schema()
                 }.

-callback structs() -> [name()].
-callback fields(name()) -> [field()].
-callback translations() -> [name()].
-callback translation(name()) -> [translation()].
-callback validations() -> [validation()].

-optional_callbacks([translations/0, translation/1, validations/0]).

-define(VIRTUAL_ROOT, "").
-define(ERR(Code, Context), {Code, Context}).
-define(ERRS(Code, Context), [?ERR(Code, Context)]).
-define(VALIDATION_ERRS(Context), ?ERRS(validation_error, Context)).
-define(TRANSLATION_ERRS(Context), ?ERRS(translation_error, Context)).

-define(DEFAULT_NULLABLE, true).

-define(EMPTY_BOX, #{}).

%% behaviour APIs
-spec structs(schema()) -> [name()].
structs(Mod) when is_atom(Mod) -> Mod:structs();
structs(#{structs := Names}) -> Names.

-spec fields(schema(), name()) -> [field()].
fields(Mod, Name) when is_atom(Mod) -> Mod:fields(Name);
fields(#{fields := Fields}, ?VIRTUAL_ROOT) when is_list(Fields) -> Fields;
fields(#{fields := Fields}, Name) -> maps:get(Name, Fields).

-spec translations(schema()) -> [name()].
translations(Mod) when is_atom(Mod) ->
    case erlang:function_exported(Mod, translations, 0) of
        false -> [];
        true -> Mod:translations()
    end;
translations(#{translations := Trs}) -> maps:keys(Trs);
translations(Sc) when is_map(Sc) -> [].

-spec translation(schema(), name()) -> [translation()].
translation(Mod, Name) when is_atom(Mod) -> Mod:translation(Name);
translation(#{translations := Trs}, Name) -> maps:get(Name, Trs).

-spec validations(schema()) -> [validation()].
validations(Mod) when is_atom(Mod) ->
    case erlang:function_exported(Mod, validations, 0) of
        false -> [];
        true -> Mod:validations()
    end;
validations(Sc) -> maps:get(validations, Sc, []).

%% @doc Find struct name from a guess.
find_struct(Schema, StructName) ->
    Names = [{bin(N), N} || N <- structs(Schema)],
    case lists:keyfind(bin(StructName), 1, Names) of
        false -> throw({unknown_struct_name, Schema, StructName});
        {_, N} -> N
    end.

%% @doc generates application env from a parsed .conf and a schema module.
%% For example, one can set the output values by
%%    lists:foreach(fun({AppName, Envs}) ->
%%        [application:set_env(AppName, Par, Val) || {Par, Val} <- Envs]
%%    end, hocon_schema_generate(Schema, Conf)).
-spec(generate(schema(), hocon:config()) -> [proplists:property()]).
generate(Schema, Conf) ->
    generate(Schema, Conf, #{}).

generate(Schema, Conf, Opts) ->
    {Mapped, _NewConf} = map_translate(Schema, Conf, Opts),
    Mapped.

-spec(map_translate(schema(), hocon:config(), opts()) ->
    {[proplists:property()], hocon:config()}).
map_translate(Schema, Conf, Opts) ->
    {Mapped, NewConf} = map(Schema, Conf, all, Opts),
    Translated = translate(Schema, NewConf, Mapped),
    {nest(Translated), NewConf}.

%% @private returns a nested proplist with atom keys
-spec(nest([proplists:property()]) -> [proplists:property()]).
nest(Proplist) ->
    nest(Proplist, []).

nest([], Acc) ->
    Acc;
nest([{Field, Value} | More], Acc) ->
    nest(More, set_value(Field, Acc, Value)).

set_value([LastToken], Acc, Value) ->
    Token = list_to_atom(LastToken),
    lists:keystore(Token, 1, Acc, {Token, Value});
set_value([HeadToken | MoreTokens], PList, Value) ->
    Token = list_to_atom(HeadToken),
    OldValue = proplists:get_value(Token, PList, []),
    lists:keystore(Token, 1, PList, {Token, set_value(MoreTokens, OldValue, Value)}).

-spec translate(schema(), hocon:config(), [proplists:property()]) -> [proplists:property()].
translate(Schema, Conf, Mapped) ->
    case translations(Schema) of
        [] -> Mapped;
        Namespaces ->
            Res = lists:append([do_translate(translation(Schema, N), str(N), Conf, Mapped) ||
                        N <- Namespaces]),
            ok = assert_no_error(Schema, Res),
            %% rm field if translation returns undefined
            [{K, V} || {K, V} <- lists:ukeymerge(1, Res, Mapped), V =/= undefined]
    end.

do_translate([], _Namespace, _Conf, Acc) -> Acc;
do_translate([{MappedField, Translator} | More], Namespace, Conf, Acc) ->
    MappedField0 = Namespace ++ "." ++ MappedField,
    try Translator(Conf) of
        Value ->
            do_translate(More, Namespace, Conf, [{string:tokens(MappedField0, "."), Value} | Acc])
    catch
        Exception : Reason : St ->
            Error = {error, ?TRANSLATION_ERRS(#{reason => Reason,
                                                stacktrace => St,
                                                value_path => MappedField0,
                                                exception => Exception
                                               })},
            do_translate(More, Namespace, Conf, [Error | Acc])
    end.

assert_integrity(Schema, Conf0, #{is_richmap := IsRichMap}) ->
    Conf = case IsRichMap of
               true -> richmap_to_map(Conf0);
               false -> Conf0
           end,
    Names = validations(Schema),
    Errors = assert_integrity(Schema, Names, Conf, []),
    ok = assert_no_error(Schema, Errors).

assert_integrity(_Schema, [], _Conf, Result) -> lists:reverse(Result);
assert_integrity(Schema, [{Name, Validator} | Rest], Conf, Acc) ->
    try Validator(Conf) of
        OK when OK =:= true orelse OK =:= ok ->
            assert_integrity(Schema, Rest, Conf, Acc);
        Other ->
            assert_integrity(Schema, Rest, Conf,
                             [{error, ?VALIDATION_ERRS(#{reason => integrity_validation_failure,
                                                         validation_name => Name,
                                                         result => Other})}])
    catch
        Exception : Reason : St ->
            Error = {error, ?VALIDATION_ERRS(#{reason => integrity_validation_crash,
                                               validation_name => Name,
                                               exception => {Exception, Reason},
                                               stacktrace => St
                                              })},
            assert_integrity(Schema, Rest, Conf, [Error | Acc])
    end.

%% @doc Check richmap input against schema.
%% Returns a new config with:
%% 1) default values from schema if not found in input config
%% 2) environment variable overrides applyed
-spec(check(schema(), hocon:config()) -> hocon:config()).
check(Schema, Conf) ->
    check(Schema, Conf, #{}).

check(Schema, Conf, Opts0) ->
    Opts = maps:merge(#{is_richmap => true, atom_key => false}, Opts0),
    do_check(Schema, Conf, Opts, all).

%% @doc Check plain-map input against schema.
%% Returns a new config with:
%% 1) default values from schema if not found in input config
%% 2) environment variable overrides applyed.
%% Returns a plain map (not richmap).
check_plain(Schema, Conf) ->
    check_plain(Schema, Conf, #{}).

check_plain(Schema, Conf, Opts0) ->
    Opts = maps:merge(#{is_richmap => false,
                        atom_key => false
                       }, Opts0),
    check_plain(Schema, Conf, Opts, all).

check_plain(Schema, Conf, Opts0, RootNames) ->
    Opts = maps:merge(#{is_richmap => false,
                        atom_key => false
                       }, Opts0),
    do_check(Schema, Conf, Opts, RootNames).

do_check(Schema, Conf, Opts0, RootNames) ->
    Opts = maps:merge(#{nullable => false}, Opts0),
    %% discard mappings for check APIs
    {_DiscardMappings, NewConf} = map(Schema, Conf, RootNames, Opts),
    NewConf.

maybe_convert_to_plain_map(Conf, #{is_richmap := true, return_plain := true}) ->
    richmap_to_map(Conf);
maybe_convert_to_plain_map(Conf, _Opts) ->
    Conf.

maybe_covert_keys_to_atom(Conf, #{atom_key := true}) ->
    atom_key_map(Conf);
maybe_covert_keys_to_atom(Conf, _Opts) ->
    Conf.

-spec map(schema(), hocon:config()) -> {[proplists:property()], hocon:config()}.
map(Schema, Conf) ->
    RootNames = structs(Schema),
    map(Schema, Conf, RootNames, #{}).

-spec map(schema(), hocon:config(), all | [name()]) ->
        {[proplists:property()], hocon:config()}.
map(Schema, Conf, RootNames) ->
    map(Schema, Conf, RootNames, #{}).

-spec map(schema(), hocon:config(), all | [name()], opts()) ->
        {[proplists:property()], hocon:config()}.
map(Schema, Conf, all, Opts) ->
    map(Schema, Conf, structs(Schema), Opts);
map(Schema, Conf, RootNames, Opts0) ->
    Opts = maps:merge(#{schema => Schema,
                        is_richmap => true
                        }, Opts0),
    {EnvNamespace, Envs} = collect_envs(Opts0),
    F =
        fun (RootName, {MappedAcc, ConfAcc0}) ->
                ok = assert_no_dot(Schema, RootName),
                ConfAcc = apply_env(EnvNamespace, Envs, RootName, ConfAcc0, Opts),
                RootValue = get_field(Opts, RootName, ConfAcc),
                {Mapped, NewRootValue} =
                    do_map(fields(Schema, RootName), RootValue,
                           Opts#{stack => [RootName || RootName =/= ?VIRTUAL_ROOT]}),
                NewConfAcc =
                    case NewRootValue of
                        undefined -> ConfAcc;
                        _ -> put_value(Opts, RootName, unbox(Opts, NewRootValue), ConfAcc)
                    end,
                {lists:append(MappedAcc, Mapped), NewConfAcc}
        end,
    {Mapped, NewConf} = lists:foldl(F, {[], Conf}, RootNames),
    ok = assert_no_error(Schema, Mapped),
    ok = assert_integrity(Schema, NewConf, Opts),
    {Mapped, maybe_covert_keys_to_atom(
                maybe_convert_to_plain_map(NewConf, Opts), Opts)}.

%% Assert no dot in root struct name.
%% This is because the dot will cause root name to be splited,
%% which in turn makes the implimentation complicated.
%%
%% e.g. if a root name is 'a.b.c', the schema is only defined
%% for data below `c` level.
%% `a` and `b` are implicitly single-filed structs.
%%
%% In this case if a non map value is assigned, such as `a.b=1`,
%% the check code will crash rather than reporting a useful error reason.
assert_no_dot(_, ?VIRTUAL_ROOT) -> ok;
assert_no_dot(Schema, RootName) ->
    case split(RootName) of
        [_] -> ok;
        _ -> error({bad_root_name, Schema, RootName})
    end.

str(A) when is_atom(A) -> atom_to_list(A);
str(B) when is_binary(B) -> binary_to_list(B);
str(S) when is_list(S) -> S.

bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(S) -> iolist_to_binary(S).

do_map(Fields, Value, Opts) ->
    case unbox(Opts, Value) of
        undefined ->
            case maps:get(nullable, Opts, ?DEFAULT_NULLABLE) of
                true -> do_map2(Fields, boxit(Opts, undefined, ?EMPTY_BOX), Opts);
                false -> {validation_errs(Opts, not_nullable, undefined), undefined}
            end;
        V when is_map(V) ->
            do_map2(Fields, Value, Opts);
        _ ->
            {validation_errs(Opts, bad_value_for_struct, Value), Value}
    end.

%% Conf must be a map from here on
do_map2([{[$$ | _] = _Wildcard, Schema}], Conf, Opts) ->
    %% wildcard: support dynamic filed names.
    %% e.g. in this config:
    %%     #{config => #{internal => #{val => 1},
    %%                   external => #{val => 2}}
    %% `internal` and `external` share the same schema, which is_map
    %%     [{"val", #{type => integer()}}]
    %%
    %% If there is no wildcard, the enclosing schema should be:
    %%     [{"internal", #{type => "val"}}
    %%      {"external", #{type => "val"}}]
    %%
    %% This will not allow us to add more fields without changing
    %% the schema (source code). So, wildcard is for the rescue:
    %% The enclosing field name can be defined with a leading $
    %% e.g.
    %%     [{"$name", #{type => "val"}}].
    Keys = maps_keys(unbox(Opts, Conf)),
    FieldNames = [str(K) || K <- Keys],
    % All objects in this map should share the same schema.
    Fields = [{FieldName, Schema} || FieldName <- FieldNames],
    do_map(Fields, Conf, Opts); %% start over
do_map2(Fields, Value, Opts) ->
    SchemaFieldNames = [N || {N, _Schema} <- Fields],
    DataFieldNames = maps_keys(unbox(Opts, Value)),
    case check_unknown_fields(Opts, SchemaFieldNames, DataFieldNames) of
        ok -> map_fields(Fields, Value, [], Opts);
        Errors -> {Errors, Value}
    end.

map_fields([], Conf, Mapped, _Opts) ->
    {Mapped, Conf};
map_fields([{FieldName, FieldSchema} | Fields], Conf0, Acc, Opts) ->
    FieldType = field_schema(FieldSchema, type),
    FieldValue0 = get_field(Opts, FieldName, Conf0),
    NewOpts = push_stack(Opts, FieldName),
    FieldValue = resolve_field_value(FieldSchema, FieldValue0, NewOpts),
    {FAcc, FValue} = map_one_field(FieldType, FieldSchema, FieldValue, NewOpts),
    Conf = put_value(Opts, FieldName, unbox(Opts, FValue), Conf0),
    map_fields(Fields, Conf, FAcc ++ Acc, Opts).

map_one_field(FieldType, FieldSchema, FieldValue, Opts) ->
    {Acc, NewValue} = map_field(FieldType, FieldSchema, FieldValue, Opts),
    case find_errors(Acc) of
        ok ->
            Mapped = maybe_mapping(field_schema(FieldSchema, mapping),
                                   plain_value(NewValue, Opts)),
            {Mapped ++ Acc, NewValue};
        _ ->
            {Acc, FieldValue}
    end.

map_field({ref, Module, Ref}, _FieldSchema, Value, Opts) ->
    %% Switching to another module, good luck.
    do_map(Module:fields(Ref), Value, Opts#{schema := Module});
map_field({ref, Ref}, _FieldSchema, Value, #{schema := Schema} = Opts) ->
    Fields = fields(Schema, Ref),
    do_map(Fields, Value, Opts);
map_field(Ref, _FieldSchema, Value, #{schema := Schema} = Opts) when is_list(Ref) ->
    Fields = fields(Schema, Ref),
    do_map(Fields, Value, Opts);
map_field(?UNION(Types), Schema0, Value, Opts) ->
    %% union is not a boxed value
    F = fun(Type) ->
                %% go deep with union member's type, but all
                %% other schema information should be inherited from the enclosing schema
                Schema = fun(type) -> Type;
                            (Other) -> field_schema(Schema0, Other)
                         end,
                map_field(Type, Schema, Value, Opts) end,
    case do_map_union(Types, F, #{}, Opts) of
        {ok, {Mapped, NewValue}} -> {Mapped, NewValue};
        Error -> {Error, Value}
    end;
map_field(?ARRAY(Type), _FieldSchema, Value0, Opts) ->
    %% array needs an unbox
    Array = unbox(Opts, Value0),
    F= fun(Elem) -> map_field(Type, Type, Elem, Opts) end,
    case is_list(Array) of
        true ->
            case do_map_array(F, Array, [], 1) of
                {ok, NewArray} ->
                    true = is_list(NewArray), %% assert
                    %% and we need to box it back
                    {[], boxit(Opts, NewArray, Value0)};
                {error, Reasons} ->
                    {[{error, Reasons}], Value0}
            end;
        false when Array =:= undefined ->
            {[], undefined};
        false ->
            {validation_errs(Opts, not_array, Value0), Value0}
    end;
map_field(Type, Schema, Value0, Opts) ->
    %% primitive type
    Value = unbox(Opts, Value0),
    PlainValue = plain_value(Value, Opts),
    try apply_converter(Schema, PlainValue) of
        ConvertedValue ->
            Validators = add_default_validator(field_schema(Schema, validator), Type),
            ValidationResult = validate(Opts, Schema, ConvertedValue, Validators),
            {ValidationResult, boxit(Opts, ConvertedValue, Value0)}
    catch
        C : E : St ->
            {validation_errs(Opts, #{reason => converter_crashed,
                                     exception => {C, E},
                                     stacktrace => St
                                     }), Value0}
    end.

maps_keys(undefined) -> [];
maps_keys(Map) -> maps:keys(Map).

check_unknown_fields(Opts, SchemaFieldNames0, DataFieldNames) ->
    SchemaFieldNames = lists:map(fun bin/1, SchemaFieldNames0),
    case DataFieldNames -- SchemaFieldNames of
        [] ->
            ok;
        UnknownFileds ->
            validation_errs(Opts, #{reason => unknown_fields,
                                    path => path(Opts),
                                    unknown=> UnknownFileds,
                                    expected => SchemaFieldNames})
    end.

is_nullable(Opts, Schema) ->
    case field_schema(Schema, nullable) of
        undefined -> maps:get(nullable, Opts, ?DEFAULT_NULLABLE);
        Bool when is_boolean(Bool) -> Bool
    end.

field_schema(Type, SchemaKey) when ?IS_TYPEREFL(Type) ->
    field_schema(hoconsc:t(Type), SchemaKey);
field_schema(?ARRAY(_) = Array, SchemaKey) ->
    field_schema(hoconsc:t(Array), SchemaKey);
field_schema(?UNION(_) = Union, SchemaKey) ->
    field_schema(hoconsc:t(Union), SchemaKey);
field_schema(?ENUM(_) = Enum, SchemaKey) ->
    field_schema(hoconsc:t(Enum), SchemaKey);
field_schema(FieldSchema, SchemaKey) when is_function(FieldSchema, 1) ->
    FieldSchema(SchemaKey);
field_schema(FieldSchema, SchemaKey) when is_map(FieldSchema) ->
    maps:get(SchemaKey, FieldSchema, undefined).

maybe_mapping(undefined, _) -> []; % no mapping defined for this field
maybe_mapping(_, undefined) -> []; % no value retrieved fro this field
maybe_mapping(MappedPath, PlainValue) ->
    [{string:tokens(MappedPath, "."), PlainValue}].

push_stack(#{stack := Stack} = X, New) ->
    X#{stack := [New | Stack]}.

%% get type validation stack.
path(#{stack := Stack}) -> string:join(lists:reverse(lists:map(fun str/1, Stack)), ".").

do_map_union([], _TypeCheck, PerTypeResult, Opts) ->
    validation_errs(Opts, #{reason => matched_no_union_member,
                            mismatches => PerTypeResult});
do_map_union([Type | Types], TypeCheck, PerTypeResult, Opts) ->
    {Mapped, Value} = TypeCheck(Type),
    case find_errors(Mapped) of
        ok ->
            {ok, {Mapped, Value}};
        {error, Reasons} ->
            do_map_union(Types, TypeCheck, PerTypeResult#{Type => Reasons}, Opts)
    end.

do_map_array(_F, [], Elems, _Index) ->
    {ok, lists:reverse(Elems)};
do_map_array(F, [Elem | Rest], Res, Index) ->
    {Mapped, NewElem} = F(Elem),
    %% Mapped is only used to collect errors of array element checks,
    %% as it is impossible to apply mappings for array elements
    %% if there is such a need, use wildcard instead
    case find_errors(Mapped) of
        ok -> do_map_array(F, Rest, [NewElem | Res], Index + 1);
        {error, Reasons} -> {error, add_index_to_error_context(Reasons, Index)}
    end.

add_index_to_error_context([], _) -> [];
add_index_to_error_context([{validation_error, Context} | More], Index) ->
    [{validation_error, Context#{array_index => Index}}
     | add_index_to_error_context(More, Index)].

resolve_field_value(Schema, FieldValue, Opts) ->
    case get_override_env(Schema, Opts) of
        undefined ->
            resolve_default_override(Schema, FieldValue, Opts);
        EnvValue ->
            maybe_mkrich(Opts, EnvValue, ?EMPTY_BOX)
    end.

resolve_default_override(Schema, FieldValue, Opts) ->
    case unbox(Opts, FieldValue) of
        ?FROM_ENV_VAR(EnvName, EnvValue) ->
            log_env_override(Schema, Opts, EnvName, path(Opts), EnvValue),
            maybe_mkrich(Opts, EnvValue, ?EMPTY_BOX);
        _ ->
            maybe_use_default(field_schema(Schema, default), FieldValue, Opts)
    end.

%% use default value if field value is 'undefined'
maybe_use_default(undefined, Value, _Opts) -> Value;
maybe_use_default(Default, undefined, Opts) ->
    maybe_mkrich(Opts, Default, ?EMPTY_BOX);
maybe_use_default(_, Value, _Opts) -> Value.

collect_envs(Opts) ->
    Ns = case os:getenv("HOCON_ENV_OVERRIDE_PREFIX") of
             V when V =:= false orelse V =:= [] -> undefined;
             Prefix -> Prefix
         end,
    case Ns of
        undefined -> {undefined, []};
        _ -> {Ns, collect_envs(Ns, Opts)}
    end.

collect_envs(Ns, Opts) ->
    [begin
         [Name, Value] = string:split(KV, "="),
         {Name, read_hocon_val(Value, Opts)}
     end || KV <- os:getenv(), string:prefix(KV, Ns) =/= nomatch].

read_hocon_val("", _Opts) -> "";
read_hocon_val(Value, Opts) ->
    case hocon:binary(Value, #{}) of
        {ok, HoconVal} -> HoconVal;
        {error, _} -> read_informal_hocon_val(Value, Opts)
    end.

read_informal_hocon_val(Value, Opts) ->
    BoxedVal = "fake_key=" ++ Value,
    case hocon:binary(BoxedVal, #{}) of
        {ok, HoconVal} ->
            maps:get(<<"fake_key">>, HoconVal);
        {error, Reason} ->
            Msg = iolist_to_binary(
                    io_lib:format(
                      "invalid_hocon_string: ~p,reason: ~p",
                      [Value, Reason])),
            log(Opts, warning, Msg),
            Value
    end.

apply_env(_Ns, [], _RootName, Conf, _Opts) -> Conf;
apply_env(Ns, [{VarName, V} | More], RootName, Conf, Opts) ->
    K = string:prefix(VarName, Ns),
    Path0 = string:split(string:lowercase(K), "__", all),
    Path1 = lists:filter(fun(N) -> N =/= [] end, Path0),
    NewConf = case RootName =:= ?VIRTUAL_ROOT orelse
                   (Path1 =/= [] andalso bin(RootName) =:= bin(hd(Path1))) of
                  true ->
                      Path = string:join(Path1, "."),
                      %% it lacks schema info here, so we need to tag the value '$FROM_ENV_VAR'
                      %% %% %% and the value will be logged later when checking against schema
                      %% %% %% so we know if the value is sensitive or not
                      put_value(Opts, Path, ?FROM_ENV_VAR(VarName, V), Conf);
                  false ->
                      Conf
              end,
    apply_env(Ns, More, RootName, NewConf, Opts).

log_env_override(Schema, Opts, Var, K, V0) ->
    V = obfuscate(Schema, V0),
    log(Opts, info, #{hocon_env_var_name => Var, path => K, value => V}).

obfuscate(Schema, Value) ->
    case field_schema(Schema, sensitive) of
        true -> "*******";
        _ -> Value
    end.


log(#{logger := Logger}, Level, Msg) ->
    Logger(Level, Msg);
log(_Opts, Level, Msg) ->
    logger:log(Level, Msg).

unbox(_, undefined) -> undefined;
unbox(#{is_richmap := false}, Value) -> Value;
unbox(#{is_richmap := true}, Boxed) -> unbox(Boxed).

unbox(Boxed) ->
    case is_map(Boxed) andalso maps:is_key(value, Boxed) of
        true -> maps:get(value, Boxed);
        false -> error({bad_richmap, Boxed})
    end.

safe_unbox(MaybeBox) ->
    case maps:get(value, MaybeBox, undefined) of
        undefined -> #{};
        Value -> Value
    end.

boxit(#{is_richmap := false}, Value, _OldValue) -> Value;
boxit(#{is_richmap := true}, Value, undefined) -> boxit(Value, ?EMPTY_BOX);
boxit(#{is_richmap := true}, Value, Box) -> boxit(Value, Box).

boxit(Value, Box) -> Box#{value => Value}.

%% nested boxing
maybe_mkrich(#{is_richmap := false}, Value, _Box) ->
    Value;
maybe_mkrich(#{is_richmap := true}, Value, Box) ->
    hocon_util:do_deep_merge(mkrich(Value), Box).

mkrich(Arr) when is_list(Arr) ->
    NewArr = [mkrich(I) || I <- Arr],
    boxit(NewArr, ?EMPTY_BOX);
mkrich(Map) when is_map(Map) ->
    boxit(maps:from_list(
            [{Name, mkrich(Value)} || {Name, Value} <- maps:to_list(Map)]), ?EMPTY_BOX);
mkrich(Val) ->
    boxit(Val, ?EMPTY_BOX).

get_field(_Opts, ?VIRTUAL_ROOT, Value) -> Value;
get_field(#{is_richmap := true}, Path, Conf) -> deep_get(Path, Conf);
get_field(#{is_richmap := false}, Path, Conf) -> plain_get(Path, Conf).

%% put (maybe deep) value to map/richmap
%% e.g. "path.to.my.value"
put_value(_Opts, _Path, undefined, Conf) ->
    Conf;
put_value(#{is_richmap := true}, Path, V, Conf) ->
    deep_put(Path, V, Conf);
put_value(#{is_richmap := false}, Path, V, Conf) ->
    plain_put(split(Path), V, Conf).

split(Path) -> lists:flatten(do_split(str(Path))).

do_split([]) -> [];
do_split(Path) when ?IS_NON_EMPTY_STRING(Path) ->
    [bin(I) || I <- string:tokens(Path, ".")];
do_split([H | T]) ->
    [do_split(H) | do_split(T)].

get_override_env(Schema, Opts) ->
    case field_schema(Schema, override_env) of
        undefined ->
            undefined;
        Var ->
            case os:getenv(str(Var)) of
                V when V =:= false orelse V =:= [] ->
                    undefined;
                V ->
                    log_env_override(Schema, Opts, Var, path(Opts), V),
                    read_hocon_val(V, Opts)
            end
    end.

-spec(apply_converter(typefunc(), term()) -> term()).
apply_converter(Schema, Value) ->
    case {field_schema(Schema, converter), field_schema(Schema, type)}  of
        {undefined, Type} ->
            hocon_schema_builtin:convert(Value, Type);
        {Converter, _} ->
            Converter(Value)
    end.

add_default_validator(undefined, Type) ->
    do_add_default_validator([], Type);
add_default_validator(Validator, Type) when is_function(Validator) ->
    add_default_validator([Validator], Type);
add_default_validator(Validators, Type) ->
    true = lists:all(fun(F) -> is_function(F, 1) end, Validators), %% assert
    do_add_default_validator(Validators, Type).

do_add_default_validator(Validators, ?ENUM(Symbols)) ->
    [fun(Value) -> check_enum_sybol(Value, Symbols) end | Validators];
do_add_default_validator(Validators, Type) ->
    TypeChecker = fun (Value) -> typerefl:typecheck(Type, Value) end,
    [TypeChecker | Validators].

check_enum_sybol(Value, Symbols) when is_atom(Value) ->
    case lists:member(Value, Symbols) of
        true -> ok;
        false -> {error, not_a_enum_symbol}
    end;
check_enum_sybol(_Value, _Symbols) ->
    {error, unable_to_convert_to_enum_symbol}.


validate(Opts, Schema, Value, Validators) ->
    validate(Opts, Schema, Value, is_nullable(Opts, Schema), Validators).

validate(_Opts, _Schema, undefined, true, _Validators) ->
    []; % do not validate if no value is set
validate(Opts, _Schema, undefined, false, _Validators) ->
    validation_errs(Opts, not_nullable, undefined);
validate(Opts, Schema, Value, _IsNullable, Validators) ->
    do_validate(Opts, Schema, Value, Validators).

%% returns on the first failure
do_validate(_Opts, _Schema, _Value, []) -> [];
do_validate(Opts, Schema, Value, [H | T]) ->
    try H(Value) of
        OK when OK =:= ok orelse OK =:= true ->
            do_validate(Opts, Schema, Value, T);
        false ->
            validation_errs(Opts, returned_false, obfuscate(Schema, Value));
        {error, Reason} ->
            validation_errs(Opts, Reason, obfuscate(Schema, Value))
    catch
        C : E : St ->
            validation_errs(Opts, #{exception => {C, E},
                                    stacktrace => St
                                   }, obfuscate(Schema, Value))
    end.

validation_errs(Opts, Reason, Value) ->
    validation_errs(Opts, #{reason => Reason, value => Value}).

validation_errs(Opts, Context) ->
    [{error, ?VALIDATION_ERRS(Context#{path => path(Opts)})}].

plain_value(Value, #{is_richmap := false}) -> Value;
plain_value(Value, #{is_richmap := true}) -> richmap_to_map(Value).

%% @doc get a child node from map.
plain_get(Path, Conf) ->
    do_plain_get(split(Path), Conf).

do_plain_get([], Conf) ->
    %% value as-is
    Conf;
do_plain_get([H | T], Conf) ->
    Child = maps:get(H, Conf, undefined),
    do_plain_get(T, Child).

%% @doc get a child node from richmap.
%% Key (first arg) can be "foo.bar.baz" or ["foo.bar", "baz"] or ["foo", "bar", "baz"].
-spec deep_get(string() | [string()], hocon:config()) -> hocon:config() | undefined.
deep_get(Path, Conf) ->
    do_deep_get(split(Path), Conf).

do_deep_get([], Value) ->
    %% terminal value
    Value;
do_deep_get([H | T], EnclosingMap) ->
    %% `value` must exist, must be a richmap otherwise
    %% a bug in in the caller
    Value = maps:get(value, EnclosingMap),
    case is_map(Value) of
        true ->
            case maps:get(H, Value, undefined) of
                undefined ->
                    %% no such field
                    undefined;
                FieldValue ->
                    do_deep_get(T, FieldValue)
            end;
        false ->
            undefined
    end.

%% @doc Get a child node from richmap and
%% lookup the value of the given tag in the child node
deep_get(Path, RichMap, Tag) ->
    deep_get(Path, RichMap, Tag, undefined).

deep_get(Path, RichMap, Tag, Default) ->
    case deep_get(Path, RichMap) of
        undefined -> Default;
        Map -> maps:get(Tag, Map)
    end.

-spec plain_put([binary()], term(), hocon:confing()) -> hocon:config().
plain_put([], Value, _Old) -> Value;
plain_put([Name | Path], Value, Conf) when is_map(Conf) ->
    FieldV = maps:get(Name, Conf, #{}),
    NewFieldV = plain_put(Path, Value, FieldV),
    Conf#{Name => NewFieldV}.

%% put unboxed value to the richmap box
%% this function is called places where there is no boxing context
%% so it has to accept unboxed value.
deep_put(Path, Value, Conf) ->
    put_rich(split(Path), Value, Conf).

put_rich([], Value, Box) ->
    boxit(Value, Box);
put_rich([Name | Path], Value, Box) ->
    BoxV = safe_unbox(Box),
    FieldV = maps:get(Name, BoxV, #{}),
    NewFieldV = put_rich(Path, Value, FieldV),
    NewBoxV = BoxV#{Name => NewFieldV},
    boxit(NewBoxV, Box).

%% @doc Convert richmap to plain-map.
richmap_to_map(RichMap) when is_map(RichMap) ->
    richmap_to_map(maps:iterator(RichMap), #{});
richmap_to_map(Array) when is_list(Array) ->
    [richmap_to_map(R) || R <- Array];
richmap_to_map(Other) ->
    Other.

richmap_to_map(Iter, Map) ->
    case maps:next(Iter) of
        {metadata, _, I} ->
            richmap_to_map(I, Map);
        {type, _, I} ->
            richmap_to_map(I, Map);
        {value, M, _} when is_map(M) ->
            richmap_to_map(maps:iterator(M), #{});
        {value, A, _} when is_list(A) ->
            [richmap_to_map(R) || R <- A];
        {value, V, _} ->
            V;
        {K, V, I} ->
            richmap_to_map(I, Map#{K => richmap_to_map(V)});
        none ->
            Map
    end.

%% @doc Get (maybe nested) field value for the given path.
-spec get_value(string(), hocon:config()) -> term().
get_value(Path, Config) ->
    plain_get(Path, Config).

assert_no_error(Schema, List) ->
    case find_errors(List) of
        ok -> ok;
        {error, Reasons} -> throw({Schema, Reasons})
    end.

%% find error but do not throw, return result
find_errors(Proplist) ->
    case do_find_error(Proplist, []) of
        [] -> ok;
        Reasons -> {error, lists:flatten(Reasons)}
    end.

do_find_error([], Res) ->
    Res;
do_find_error([{error, E} | More], Errors) ->
    do_find_error(More, [E | Errors]);
do_find_error([_ | More], Errors) ->
    do_find_error(More, Errors).

atom_key_map(BinKeyMap) when is_map(BinKeyMap) ->
    maps:fold(
        fun(K, V, Acc) when is_binary(K) ->
              Acc#{binary_to_existing_atom(K, utf8) => atom_key_map(V)};
           (K, V, Acc) when is_atom(K) ->
              %% richmap keys
              Acc#{K => atom_key_map(V)}
        end, #{}, BinKeyMap);
atom_key_map(ListV) when is_list(ListV) ->
    [atom_key_map(V) || V <- ListV];
atom_key_map(Val) -> Val.
