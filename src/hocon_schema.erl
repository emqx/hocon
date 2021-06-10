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
        ]).

-export([map/2, map/3, map/4]).
-export([translate/3]).
-export([generate/2]).
-export([check/2, check/3, check_plain/2, check_plain/3]).
-export([deep_get/2, deep_get/3, deep_get/4, deep_put/4, plain_put/4, plain_get/2]).
-export([richmap_to_map/1]).

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

-type name() :: atom() | string().
-type type() :: typerefl:type() %% primitive (or complex, but terminal) type
              | name() %% reference to another struct
              | ?ARRAY(type()) %% array of
              | ?UNION([type()]) %% one-of
              .

-type typefunc() :: fun((_) -> _).
-type translationfunc() :: fun((hocon:config()) -> hocon:config()).
-type field_schema() :: typerefl:type()
                      | ?UNION([type()])
                      | ?ARRAY(type())
                      | #{ type := type()
                         , default => term()
                         , mapping => string()
                         , converter => function()
                         , validator => function()
                         , override_env => string()
                         }.

-type field() :: {name(), typefunc() | field_schema()}.
-type translation() :: {name(), translationfunc()}.
-type schema() :: module()
                | #{ structs := [name()]
                   , fileds := fun((name()) -> [field()])
                   , translations => [name()]
                   , translation => fun((name()) -> [translation()])
                   }.

-define(IS_NON_EMPTY_STRING(X), (is_list(X) andalso X =/= [] andalso is_integer(hd(X)))).
-type raw_name() :: string() | [string()].
-type getter() :: fun((raw_name(), hocon:config()) -> term()).
-type setter() :: fun((raw_name(), term(), hocon:config()) -> term()).
-type loggerfunc() :: fun((atom(), map()) -> ok).
-type opts() :: #{ getter => getter()
                 , setter => setter()
                 , is_richmap => boolean()
                 , logger => loggerfunc()
                 , stack => [name()]
                 }.

-callback structs() -> [name()].
-callback fields(name()) -> [field()].
-callback translations() -> [name()].
-callback translation(name()) -> [translation()].

-optional_callbacks([translations/0, translation/1]).

-define(IS_REF(Type), is_list(Type)
               orelse element(1, Type) =:= union
               orelse element(1, Type) =:= array).

-define(VIRTUAL_ROOT, '').
-define(ERR(Code, Context), {Code, Context}).
-define(ERRS(Code, Context), [?ERR(Code, Context)]).

-define(EMPTY_BOX, #{}).

%% behaviour APIs
-spec structs(schema()) -> [name()].
structs(Mod) when is_atom(Mod) -> Mod:structs();
structs(#{structs := Names}) -> Names.

-spec fields(schema(), name()) -> [field()].
fields(Mod, Name) when is_atom(Mod) -> Mod:fields(Name);
fields(#{fields := Fields}, ?VIRTUAL_ROOT) -> Fields;
fields(#{fields := Fields}, Name) -> maps:get(Name, Fields).

-spec translations(schema()) -> [name()].
translations(Mod) when is_atom(Mod) ->
    case erlang:function_exported(Mod, translations, 0) of
        false -> [];
        true -> Mod:translations()
    end;
translations(#{translations := Trs}) -> Trs.

-spec translation(schema(), name()) -> [translation()].
translation(Mod, Name) when is_atom(Mod) ->
    case erlang:function_exported(Mod, translation, 1) of
        false -> [];
        true -> Mod:translation(Name)
    end;
translation(#{translation := Tr}, Name) -> Tr(Name).

%% @doc generates application env from a parsed .conf and a schema module.
%% For example, one can set the output values by
%%    lists:foreach(fun({AppName, Envs}) ->
%%        [application:set_env(AppName, Par, Val) || {Par, Val} <- Envs]
%%    end, hocon_schema_generate(Schema, Conf)).
-spec(generate(schema(), hocon:config()) -> [proplists:property()]).
generate(Schema, Conf) ->
    {Mapped, NewConf} = map(Schema, Conf),
    Translated = translate(Schema, NewConf, Mapped),
    nest(Translated).

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
            ok = assert_no_error(Res),
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
        _:Reason:St ->
            Error = {error, ?ERRS(translation_error,
                                  #{reason => Reason,
                                    stacktrace => St,
                                    field => MappedField0
                                   })},
            do_translate(More, Namespace, Conf, [Error | Acc])
    end.

%% @doc Check richmap input against schema.
%% Returns a new config with:
%% 1) default values from schema if not found in input config
%% 2) environment variable overrides applyed
-spec(check(schema(), hocon:config()) -> hocon:config()).
check(Schema, Conf) ->
    check(Schema, Conf, #{}).

check(Schema, Conf, Opts0) ->
    Opts = maps:merge(#{getter => fun deep_get/2,
                        setter => fun deep_put/4
                        }, Opts0),
    do_check(Schema, Conf, Opts).

%% @doc Check plain-map input against schema.
%% Returns a new config with:
%% 1) default values from schema if not found in input config
%% 2) environment variable overrides applyed.
%% Returns a plain map (not richmap).
check_plain(Schema, Conf) ->
    check_plain(Schema, Conf, #{}).

check_plain(Schema, Conf, Opts0) ->
    Opts = maps:merge(#{getter => fun plain_get/2,
                        setter => fun plain_put/4,
                        is_richmap => false
                       }, Opts0),
    do_check(Schema, Conf, Opts).

do_check(Schema, Conf, Opts) ->
    case map(Schema, Conf, structs(Schema), Opts) of
        {[], NewConf} ->
            NewConf;
        {_Mapped, _} ->
            %% should call map/2 instead
            error({schema_supports_mapping, Schema})
    end.

-spec map(schema(), hocon:config()) -> {[proplists:property()], hocon:config()}.
map(Schema, Conf) ->
    RootNames = structs(Schema),
    map(Schema, Conf, RootNames, #{}).

-spec map(schema(), hocon:config(), [name()]) ->
        {[proplists:property()], hocon:config()}.
map(Schema, Conf, RootNames) ->
    map(Schema, Conf, RootNames, #{}).

-spec map(schema(), hocon:config(), [name()], opts()) ->
        {[proplists:property()], hocon:config()}.
map(Schema, Conf0, RootNames, Opts0) ->
    Opts = maps:merge(#{getter => fun deep_get/2,
                        setter => fun deep_put/4,
                        schema_mod => Schema,
                        is_richmap => true
                        }, Opts0),
    Conf = apply_env(Conf0, Opts),
    F =
        fun (RootName, {MappedAcc, ConfAcc}) ->
                RootValue = get_field(Opts, RootName, ConfAcc),
                {Mapped, NewRootValue} =
                    do_map(fields(Schema, RootName), RootValue, [], Opts#{stack => [RootName]}),
                NewConfAcc =
                    case NewRootValue of
                        undefined -> ConfAcc;
                        _ -> put_value(Opts, RootName, unbox(Opts, NewRootValue), ConfAcc)
                    end,
                {lists:append(MappedAcc, Mapped), NewConfAcc}
        end,
    {Mapped, NewConf} = lists:foldl(F, {[], Conf}, RootNames),
    ok = assert_no_error(Mapped),
    {Mapped, NewConf}.

str(A) when is_atom(A) -> atom_to_list(A);
str(B) when is_binary(B) -> binary_to_list(B);
str(S) when is_list(S) -> S.

do_map([{[$$ | _] = _Wildcard, _Schema}], undefined, Acc, _Opts) ->
    {Acc, undefined};
do_map([{[$$ | _] = _Wildcard, Schema}], Conf, Acc, Opts) ->
    %% wildcard, this 'virtual' boxing only exists in schema but not in data
    Keys = maps:keys(unbox(Opts, Conf)),
    FieldNames = [str(K) || K <- Keys],
    % All objects in this map should share the same schema.
    Fields = [{FieldName, Schema} || FieldName <- FieldNames],
    map_fields(Fields, Conf, Acc, Opts);
do_map(Fields, Conf, Acc, Opts) ->
    map_fields(Fields, Conf, Acc, Opts).

map_fields([], Conf, Mapped, _Opts) ->
    {Mapped, Conf};
map_fields([{FieldName, FieldSchema} | Fields], Conf0, Acc, Opts) ->
    FieldType = field_schema(FieldSchema, type),
    FieldValue0 = get_field(Opts, FieldName, Conf0),
    FieldValue = resolve_field_value(FieldSchema, FieldValue0, Opts),
    NewOpts = push_stack(Opts, FieldName),
    {FAcc, FValue} = map_one_field(FieldType, FieldSchema, FieldValue, NewOpts),
    Conf = put_value(Opts, FieldName, unbox(Opts, FValue), Conf0),
    map_fields(Fields, Conf, FAcc ++ Acc, Opts).

map_one_field(FieldType, FieldSchema, FieldValue, Opts) ->
    {Acc, NewValue} = try map_field(FieldType, FieldSchema, FieldValue, Opts)
                      catch C : E : St ->
                                NewE = #{ stack => stack(Opts)
                                        , bad_value => FieldValue
                                        , error => E
                                        },
                                erlang:raise(C, NewE, St)
                      end,
    case find_errors(Acc) of
        ok ->
            Mapped = maybe_mapping(field_schema(FieldSchema, mapping),
                                   plain_value(NewValue, Opts)),
            {Mapped ++ Acc, NewValue};
        _ ->
            {Acc, FieldValue}
    end.

map_field(?UNION(Types), Schema, Value, Opts) ->
    %% union is not a boxed value
    F = fun(Type) -> map_field(Type, Schema, Value, Opts) end,
    case do_map_union(Types, F, #{}) of
        {ok, {Mapped, NewValue}} -> {Mapped, NewValue};
        {error, Reasons} -> {[{error, Reasons}], Value}
    end;
map_field(Ref, _Schema, Value,
          #{schema_mod := SchemaModule} = Opts) when is_list(Ref) ->
    Fields = fields(SchemaModule, Ref),
    do_map(Fields, Value, [], Opts);
map_field(?ARRAY(Type), Schema, Value0, Opts) ->
    %% array needs an unbox
    Array = unbox(Opts, Value0),
    F= fun(Elem) -> map_field(Type, Schema, Elem, Opts) end,
    case is_list(Array) of
        true ->
            case do_map_array(F, Array) of
                {ok, {Mapped, NewArray}} ->
                    true = is_list(NewArray), %% assert
                    %% and we need to box it back
                    {Mapped, boxit(Opts, Array, Value0)};
                {error, Reasons} ->
                    {[{error, Reasons}], Value0}
            end;
        false when Array =:= undefined ->
            {[], undefined};
        false ->
            {[{error, ?ERRS(not_array,
                            #{stack => stack(Opts),
                              value => Value0 %% Value0 because it has metadata (when richmap)
                             })}], Value0}
    end;
map_field(Type, Schema, Value0, Opts) ->
    %% primitive type
    Value = unbox(Opts, Value0),
    PlainValue = plain_value(Value, Opts),
    ConvertedValue = apply_converter(Schema, PlainValue),
    Validators = add_default_validator(field_schema(Schema, validator), Type),
    ValidationResult = validate(ConvertedValue, Validators, Opts),
    {ValidationResult, boxit(Opts, ConvertedValue, Value0)}.

field_schema(Type, SchemaKey) when ?IS_TYPEREFL(Type) ->
    field_schema(hoconsc:t(Type), SchemaKey);
field_schema(?ARRAY(_) = Array, SchemaKey) ->
    field_schema(hoconsc:t(Array), SchemaKey);
field_schema(?UNION(_) = Union, SchemaKey) ->
    field_schema(hoconsc:t(Union), SchemaKey);
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
stack(#{stack := Stack}) -> lists:reverse(Stack).

do_map_union([], _TypeCheck, PerTypeResult) ->
    {error, ?ERRS(matched_no_union_member, #{mismatches => PerTypeResult})};
do_map_union([Type | Types], TypeCheck, PerTypeResult) ->
    {Mapped, Value} = TypeCheck(Type),
    case find_errors(Mapped) of
        ok ->
            {ok, {Mapped, Value}};
        {error, Reasons} ->
            do_map_union(Types, TypeCheck, PerTypeResult#{Type => Reasons})
    end.

do_map_array(F, Array) when is_list(Array) ->
    {Mapped, NewArray} = do_map_array2(F, Array, _Mapped = [], _ResElems = []),
    case find_errors(Mapped) of
        ok ->
            {ok, {Mapped, NewArray}};
        {error, Reasons} ->
            {error, Reasons}
    end.

do_map_array2(_F, [], Mapped, Elems) ->
    {Mapped, lists:reverse(Elems)};
do_map_array2(F, [Elem | Rest], Mapped0, Res) ->
    {Mapped, NewElem} = F(Elem),
    do_map_array2(F, Rest, Mapped ++ Mapped0, [NewElem | Res]).

resolve_field_value(Schema, FieldValue, Opts) ->
    case get_override_env(Schema) of
        undefined -> maybe_use_default(field_schema(Schema, default), FieldValue, Opts);
        EnvValue -> boxit(Opts, EnvValue, FieldValue)
    end.

%% use default value if field value is 'undefined'
maybe_use_default(undefined, Value, _Opt) -> Value;
maybe_use_default(Default, undefined, Opts) -> boxit(Opts, Default, ?EMPTY_BOX);
maybe_use_default(_, Value, _Opts) -> Value.

apply_env(Conf, Opts) ->
    case os:getenv("HOCON_ENV_OVERRIDE_PREFIX") of
        false ->
            Conf;
        Prefix ->
            AllEnvs = [string:split(string:prefix(KV, Prefix), "=")
                || KV <- os:getenv(), string:prefix(KV, Prefix) =/= nomatch],
            maybe_log(Opts, debug, #{all_envs => AllEnvs}),
            apply_env(AllEnvs, Conf, Opts)
    end.

apply_env([], Conf, _Opts) ->
    Conf;
apply_env([[K, V] | More], Conf, Opts) ->
    Field = string:join(string:replace(string:lowercase(K), "__", ".", all), ""),
    maybe_log(Opts, debug, #{hocon_env_override_key => Field, hocon_env_override_value => V}),
    apply_env(More, put_value(Opts, Field, V, Conf), Opts).

maybe_log(#{logger := Logger}, Level, Msg) ->
    Logger(Level, Msg);
maybe_log(_Opts, _, _) ->
    ok.

unbox(_, undefined) -> undefined;
unbox(#{is_richmap := false}, Value) -> Value;
unbox(#{is_richmap := true}, Boxed) -> maps:get(value, Boxed).

boxit(#{is_richmap := false}, Value, _OldValue) -> Value;
boxit(#{is_richmap := true}, Value, undefined) -> #{value => Value};
boxit(#{is_richmap := true}, Value, Box) -> Box#{value => Value}.

get_field(_Opts, ?VIRTUAL_ROOT, Value) ->
    Value;
get_field(_Opts, _Path, undefined) ->
    undefined;
get_field(#{getter := G}, Path, MaybeBoxedValue) ->
    G(str(Path), MaybeBoxedValue).

put_value(_Opts, _Field, undefined, Conf) ->
    Conf;
put_value(#{setter := F}, Field, V, Conf) ->
    F(str(Field), V, Conf, value).

get_override_env(Type) ->
    case {os:getenv("HOCON_ENV_OVERRIDE_PREFIX"), field_schema(Type, override_env)} of
        {false, _} -> undefined;
        {_, undefined} -> undefined;
        {Prefix, Key} ->
            case os:getenv(Prefix ++ Key) of
                "" -> undefined;
                false -> undefined;
                V -> V
            end
    end.

-spec(apply_converter(typefunc(), term()) -> term()).
apply_converter(Schema, Value) ->
    case {field_schema(Schema, converter), field_schema(Schema, type)}  of
        {_, Ref} when ?IS_REF(Ref) ->
            Value;
        {undefined, Type} ->
            hocon_schema_builtin:convert(Value, Type);
        {Converter, _} ->
            Converter(Value)
    end.

add_default_validator(undefined, Type) ->
    add_default_validator([], Type);
add_default_validator(Validator, Type) when is_function(Validator) ->
    add_default_validator([Validator], Type);
add_default_validator(Validators, Ref) when ?IS_REF(Ref) ->
    Validators;
add_default_validator(Validators, Type) ->
    TypeChecker = fun (Value) -> typerefl:typecheck(Type, Value) end,
    [TypeChecker | Validators].

validate(undefined, _Validators, _Opts) ->
    []; % do not validate if no value is set
validate(_Value, [], _Opts) ->
    [];
validate(Value, [H | T], Opts) ->
    case H(Value) of
        ok ->
            validate(Value, T, Opts);
        {error, Reason} ->
            [{error, ?ERRS(validation_error,
                           #{reason => Reason,
                             stack => stack(Opts)
                            })}]
    end.

plain_value(Value, #{is_richmap := false}) -> Value;
plain_value(Value, #{is_richmap := true}) -> richmap_to_map(Value).

plain_get([], Conf) ->
    %% value as-is
    Conf;
plain_get([H | T], Conf) when is_list(H) ->
    %% deep value, get by path
    {NewH, NewT} = retokenize(H, T),
    case is_map(Conf) of
        true ->
            case maps:get(NewH, Conf, undefined) of
                undefined ->
                    %% no such field
                    undefined;
                ChildConf ->
                    plain_get(NewT, ChildConf)
            end;
        false ->
            undefined
    end;
plain_get(Path, Conf) when is_list(Path) ->
    plain_get(string:tokens(Path, "."), Conf).

%% @doc get a child node from richmap.
%% Key (first arg) can be "foo.bar.baz" or ["foo.bar", "baz"] or ["foo", "bar", "baz"].
-spec deep_get(string() | [string()], hocon:config()) -> hocon:config() | undefined.
deep_get([], Value) ->
    %% terminal value
    Value;
deep_get([H | T], EnclosingMap) when is_list(H) ->
    %% deep value, get by path
    {NewH, NewT} = retokenize(H, T),
    Value = maps:get(value, EnclosingMap),
    case is_map(Value) of
        true ->
            case maps:get(NewH, Value, undefined) of
                undefined ->
                    %% no such field
                    undefined;
                FieldValue ->
                    deep_get(NewT, FieldValue)
            end;
        false ->
            undefined
    end;
deep_get(Str, RichMap) when is_list(Str) ->
    deep_get(string:tokens(Str, "."), RichMap).

%% @doc Get a child node from richmap and
%% lookup the value of the given tag in the child node
deep_get(Path, RichMap, Tag) ->
    deep_get(Path, RichMap, Tag, undefined).

deep_get(Path, RichMap, Tag, Default) ->
    case deep_get(Path, RichMap) of
        undefined -> Default;
        Map -> maps:get(Tag, Map)
    end.

-spec(plain_put(string() | [string()], term(), hocon:confing(), atom()) -> hocon:config()).
plain_put(Path, Value, Conf, value) ->
    do_plain_put(Path, Value, Conf);
plain_put(_Path, _Value, Conf, Param) when Param =/= value ->
    %% plain map does not have the ability to hold metadata
    Conf.

do_plain_put(Path, Value, Conf) when ?IS_NON_EMPTY_STRING(Path) ->
    do_plain_put(string:tokens(Path, "."), Value, Conf);
do_plain_put(Path, Value, Conf) ->
    hocon_util:do_deep_merge(Conf, make_map(Path, Value)).

make_map([], Value) ->
    Value;
make_map([Tag], Value) ->
    #{iolist_to_binary(Tag) => Value};
make_map([Tag | Tags], Value) ->
    Map = make_map(Tags, Value),
    #{iolist_to_binary(Tag) => Map}.

%% @doc put a value to the child richmap.
-spec(deep_put(string() | [string()], term(), hocon:config(), atom()) -> hocon:config()).
deep_put([], Value, Conf, Param) ->
    hocon_util:do_deep_merge(Conf, #{Param => Value});
deep_put([H | _T] = L, Value, RichMap, Param) when is_list(H) ->
    hocon_util:do_deep_merge(RichMap, #{value => nested_richmap(L, Value, Param)});
deep_put(Str, Value, RichMap, Param) when is_list(Str) ->
    deep_put(string:tokens(Str, "."), Value, RichMap, Param).

nested_richmap([H], Value, Param) ->
    case retokenize(H, []) of
        {X, []} ->
            #{iolist_to_binary(X) => #{Param => Value}};
        {NewH, NewT} ->
            #{iolist_to_binary(NewH) => #{value => nested_richmap(NewT, Value, Param)}}
    end;
nested_richmap([H | T], Value, Param) ->
    {NewH, NewT} = retokenize(H, T),
    #{iolist_to_binary(NewH) => #{value => nested_richmap(NewT, Value, Param)}}.

retokenize(H, T) ->
    case string:tokens(H, ".") of
        [X] ->
            {iolist_to_binary(X), T};
        [Token | More] ->
            {iolist_to_binary(Token), More ++ T}
    end.

resolve_array(ArrayOfRichMap) when is_list(ArrayOfRichMap) ->
    [richmap_to_map(R) || R <- ArrayOfRichMap];
resolve_array(Other) ->
    Other.

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
            resolve_array(A);
        {value, V, _} ->
            V;
        {K, V, I} ->
            richmap_to_map(I, Map#{K => richmap_to_map(V)});
        none ->
            Map
    end.

assert_no_error(List) ->
    case find_errors(List) of
        ok -> ok;
        {error, Reasons} -> throw(Reasons)
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
