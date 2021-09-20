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

-elvis([{elvis_style, god_modules, disable}]).

%% behaviour APIs
-export([ roots/1
        , fields/2
        , translations/1
        , translation/2
        , validations/1
        ]).

-export([map/2, map/3, map/4]).
-export([translate/3]).
-export([generate/2, generate/3, map_translate/3]).
-export([check/2, check/3, check_plain/2, check_plain/3, check_plain/4]).
-export([richmap_to_map/1, get_value/2, get_value/3]).
-export([namespace/1, resolve_struct_name/2, root_names/1]).
-export([field_schema/2, override/2]).
-export([find_structs/1]).

-include("hoconsc.hrl").
-include("hocon_private.hrl").

-ifdef(TEST).
-export([deep_get/2, deep_put/4]).
-export([nest/1]).
-endif.

-export_type([ field_schema/0
             , name/0
             , opts/0
             , schema/0
             , typefunc/0
             , translationfunc/0
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
                      | field_schema_map()
                      | field_schema_fun().
-type field_schema_fun() :: fun((_) -> _).
-type field_schema_map() ::
        #{ type := type()
         , default => term()
         , mapping => undefined | string()
         , converter => function()
         , validator => function()
         , override_env => string()
           %% set true if a field is allowed to be `undefined`
           %% NOTE: has no point setting it to `true` if field has a default value
         , nullable => true | false | {true, recursively} % default = true
           %% for sensitive data obfuscation (password, token)
         , sensitive => boolean()
         , desc => iodata()
         }.

-type field() :: {name(), typefunc() | field_schema()}.
-type translation() :: {name(), translationfunc()}.
-type validation() :: {name(), validationfun()}.
-type root_type() :: name() | field().
-type schema() :: module()
                | #{ roots := [root_type()]
                   , fields := #{name() => [field()]} | fun((name()) -> [field()])
                   , translations => #{name() => [translation()]} %% for config mappings
                   , validations => [validation()] %% for config integrity checks
                   , namespace => atom()
                   }.

-define(FROM_ENV_VAR(Name, Value), {'$FROM_ENV_VAR', Name, Value}).
-define(IS_NON_EMPTY_STRING(X), (is_list(X) andalso X =/= [] andalso is_integer(hd(X)))).
-type loggerfunc() :: fun((atom(), map()) -> ok).
-type opts() :: #{ logger => loggerfunc()
                 , no_conversion => boolean()
                 , atom_key => boolean()
                 , return_plain => boolean()
                   %% override_env =:= true andalso has HOCON_ENV_OVERRIDE_PREFIX env.
                   %% default is true.
                 , override_env => boolean()
                   %% By default allow all fields to be undefined.
                   %% if `nullable` is set to `false`
                   %% map or check APIs fail with validation_error.
                   %% NOTE: this option serves as default value for field's `nullable` spec
                 , nullable => boolean() %% default: true for map, false for check

                 %% below options are generated internally and should not be passed in by callers
                 , format => map | richmap
                 , stack => [name()]
                 , schema => schema()
                 , check_lazy => boolean()
                 }.

-callback namespace() -> name().
-callback roots() -> [root_type()].
-callback fields(name()) -> [field()].
-callback translations() -> [name()].
-callback translation(name()) -> [translation()].
-callback validations() -> [validation()].

-optional_callbacks([ namespace/0
                    , roots/0
                    , fields/1
                    , translations/0
                    , translation/1
                    , validations/0
                    ]).

-define(ERR(Code, Context), {Code, Context}).
-define(ERRS(Code, Context), [?ERR(Code, Context)]).
-define(VALIDATION_ERRS(Context), ?ERRS(validation_error, Context)).
-define(TRANSLATION_ERRS(Context), ?ERRS(translation_error, Context)).

-define(DEFAULT_NULLABLE, true).

-define(META_BOX(Tag, Metadata), #{?METADATA => #{Tag => Metadata}}).
-define(NULL_BOX, #{?METADATA => #{made_for => null_value}}).
-define(MAGIC, '$magic_chicken').
-define(MAGIC_SCHEMA, #{type => ?MAGIC}).

%% @doc Make a higher order schema by overriding `Base' with `OnTop'
-spec override(field_schema(), field_schema_map()) -> field_schema_fun().
override(Base, OnTop) ->
    fun(SchemaKey) ->
            case maps:is_key(SchemaKey, OnTop) of
                true -> field_schema(OnTop, SchemaKey);
                false -> field_schema(Base, SchemaKey)
            end
    end.

%% behaviour APIs
-spec roots(schema()) -> [{name(), {name(), field_schema()}}].
roots(Schema) ->
    All =
      lists:map(fun({N, T}) -> {bin(N), {N, T}};
                   (N) when is_atom(Schema) -> {bin(N), {N, ?R_REF(Schema, N)}};
                   (N) -> {bin(N), {N, ?REF(N)}}
                end, do_roots(Schema)),
    AllNames = [Name || {Name, _} <- All],
    UniqueNames = lists:usort(AllNames),
    case length(UniqueNames) =:= length(AllNames) of
        true  ->
            All;
        false ->
            error({duplicated_root_names, AllNames -- UniqueNames})
    end.

%% @doc Collect all structs defined in the given schema.
-spec find_structs(schema()) ->
        {RootNs :: name(), RootFields :: [field()],
         [{Namespace :: name(), Name :: name(), [field()]}]}.
find_structs(Schema) ->
    Roots = ?MODULE:roots(Schema),
    RootFields = lists:map(fun({_BinName, {RootFieldName, RootFieldSchema}}) ->
                                   {RootFieldName, RootFieldSchema}
                           end, Roots),
    All = find_structs(Schema, RootFields, #{}),
    RootNs = hocon_schema:namespace(Schema),
    {RootNs, RootFields,
     [{Ns, Name, Fields} || {{Ns, Name}, Fields} <- lists:keysort(1, maps:to_list(All))]}.

do_roots(Mod) when is_atom(Mod) -> Mod:roots();
do_roots(#{roots := Names}) -> Names.

-spec fields(schema(), name()) -> [field()].
fields(Mod, Name) when is_atom(Mod) ->
    Mod:fields(Name);
fields(#{fields := Fields}, Name) when is_function(Fields) ->
    Fields(Name);
fields(#{fields := Fields}, Name) when is_map(Fields) ->
    maps:get(Name, Fields).

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

%% @doc Get namespace of a schema.
-spec namespace(schema()) -> undefined | binary().
namespace(Schema) ->
    case is_atom(Schema) of
        true ->
            case erlang:function_exported(Schema, namespace, 0) of
                true  -> Schema:namespace();
                false -> undefined
            end;
        false ->
            maps:get(namespace, Schema, undefined)
    end.

%% @doc Resolve struct name from a guess.
resolve_struct_name(Schema, StructName) ->
    case lists:keyfind(bin(StructName), 1, roots(Schema)) of
        {_, {N, _Sc}} -> N;
        false -> throw({unknown_struct_name, Schema, StructName})
    end.

%% @doc Get all root names from a schema.
-spec root_names(schema()) -> [binary()].
root_names(Schema) -> [Name || {Name, _} <- roots(Schema)].

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
do_translate([{MappedField, Translator} | More], TrNamespace, Conf, Acc) ->
    MappedField0 = TrNamespace ++ "." ++ MappedField,
    try Translator(Conf) of
        Value ->
            do_translate(More, TrNamespace, Conf, [{string:tokens(MappedField0, "."), Value} | Acc])
    catch
        Exception : Reason : St ->
            Error = {error, ?TRANSLATION_ERRS(#{reason => Reason,
                                                stacktrace => St,
                                                value_path => MappedField0,
                                                exception => Exception
                                               })},
            do_translate(More, TrNamespace, Conf, [Error | Acc])
    end.

assert_integrity(Schema, Conf0, #{format := Format}) ->
    Conf = case Format of
               richmap -> richmap_to_map(Conf0);
               map -> Conf0
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
    Opts = maps:merge(#{override_env => true, format => richmap, atom_key => false}, Opts0),
    do_check(Schema, Conf, Opts, all).

%% @doc Check plain-map input against schema.
%% Returns a new config with:
%% 1) default values from schema if not found in input config
%% 2) environment variable overrides applyed.
%% Returns a plain map (not richmap).
check_plain(Schema, Conf) ->
    check_plain(Schema, Conf, #{}).

check_plain(Schema, Conf, Opts0) ->
    Opts = maps:merge(#{format => map,
                        override_env => true,
                        atom_key => false
                       }, Opts0),
    check_plain(Schema, Conf, Opts, all).

check_plain(Schema, Conf, Opts0, RootNames) ->
    Opts = maps:merge(#{format => map,
                        override_env => true,
                        atom_key => false
                       }, Opts0),
    do_check(Schema, Conf, Opts, RootNames).

do_check(Schema, Conf, Opts0, RootNames) ->
    Opts = maps:merge(#{nullable => false}, Opts0),
    %% discard mappings for check APIs
    {_DiscardMappings, NewConf} = map(Schema, Conf, RootNames, Opts),
    NewConf.

maybe_convert_to_plain_map(Conf, #{format := richmap, return_plain := true}) ->
    richmap_to_map(Conf);
maybe_convert_to_plain_map(Conf, _Opts) ->
    Conf.

-spec map(schema(), hocon:config()) -> {[proplists:property()], hocon:config()}.
map(Schema, Conf) ->
    Roots = [N || {N, _} <- roots(Schema)],
    map(Schema, Conf, Roots, #{}).

-spec map(schema(), hocon:config(), all | [name()]) ->
        {[proplists:property()], hocon:config()}.
map(Schema, Conf, RootNames) ->
    map(Schema, Conf, RootNames, #{}).

-spec map(schema(), hocon:config(), all | [name()], opts()) ->
        {[proplists:property()], hocon:config()}.
map(Schema, Conf, all, Opts) ->
    map(Schema, Conf, root_names(Schema), Opts);
map(Schema, Conf0, Roots0, Opts0) ->
    Opts = maps:merge(#{schema => Schema, format => richmap, override_env => true}, Opts0),
    Roots = resolve_root_types(roots(Schema), Roots0),
    %% assert
    lists:foreach(fun({RootName, _RootSc}) ->
                          ok = assert_no_dot(Schema, RootName)
                  end, Roots),
    Conf1 = filter_by_roots(Opts, Conf0, Roots),
    {EnvNamespace, Envs} = collect_envs(Opts),
    Conf = apply_envs(EnvNamespace, Envs, Opts, Roots, Conf1),
    {Mapped, NewConf} = do_map(Roots, Conf, Opts, ?MAGIC_SCHEMA),
    ok = assert_no_error(Schema, Mapped),
    ok = assert_integrity(Schema, NewConf, Opts),
    {Mapped, maybe_convert_to_plain_map(NewConf, Opts)}.

apply_envs(_EnvNamespace, _Envs, _Opts, [], Conf) -> Conf;
apply_envs(EnvNamespace, Envs, Opts, [{RootName, RootSc} | Roots], Conf) ->
    ShouldApply =
        case field_schema(RootSc, type) of
            ?LAZY(_) -> maps:get(check_lazy, Opts, false);
            _ -> true
        end,
    NewConf = case ShouldApply of
                  true -> apply_env(EnvNamespace, Envs, RootName, Conf, Opts);
                  false -> Conf
                end,
    apply_envs(EnvNamespace, Envs, Opts, Roots, NewConf).

%% silently drop unknown data (root level only)
filter_by_roots(Opts, Conf, Roots) ->
    Names = lists:map(fun({N, _}) -> bin(N) end, Roots),
    boxit(Opts, maps:with(Names, unbox(Opts, Conf)), Conf).

resolve_root_types(_Roots, []) -> [];
resolve_root_types(Roots, [Name | Rest]) ->
    case lists:keyfind(bin(Name), 1, Roots) of
        {_, {OrigName, Sc}} ->
            [{OrigName, Sc} | resolve_root_types(Roots, Rest)];
        false ->
            %% maybe a private struct which is not exposed in roots/0
            [{Name, hoconsc:ref(Name)} | resolve_root_types(Roots, Rest)]
    end.

%% Assert no dot in root struct name.
%% This is because the dot will cause root name to be splited,
%% which in turn makes the implimentation complicated.
%%
%% e.g. if a root name is 'a.b.c', the schema is only defined
%% for data below `c` level.
%% `a` and `b` are implicitly single-field roots.
%%
%% In this case if a non map value is assigned, such as `a.b=1`,
%% the check code will crash rather than reporting a useful error reason.
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

do_map(Fields, Value, Opts, ParentSchema) ->
    case unbox(Opts, Value) of
        undefined ->
            case is_nullable(Opts, ParentSchema) of
                {true, recursively} ->
                    {[], boxit(Opts, undefined, undefined)};
                true ->
                    do_map2(Fields, boxit(Opts, undefined, undefined), Opts,
                            ParentSchema);
                false ->
                    {validation_errs(Opts, not_nullable, undefined), undefined}
            end;
        V when is_map(V) ->
            do_map2(Fields, Value, Opts, ParentSchema);
        _ ->
            {validation_errs(Opts, bad_value_for_struct, Value), Value}
    end.

do_map2(Fields, Value0, Opts, _ParentSchema) ->
    SchemaFieldNames = [N || {N, _Schema} <- Fields],
    DataFields0 = unbox(Opts, Value0),
    DataFields = drop_nulls(Opts, DataFields0),
    Value = boxit(Opts, DataFields, Value0),
    case check_unknown_fields(Opts, SchemaFieldNames, DataFields) of
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
            Pv = plain_value(NewValue, Opts),
            Validators = validators(field_schema(FieldSchema, validator)),
            ValidationResult = validate(Opts, FieldSchema, Pv, Validators),
            case ValidationResult of
                [] ->
                    Mapped = maybe_mapping(field_schema(FieldSchema, mapping), Pv),
                    {Acc ++ Mapped, NewValue};
                Errors ->
                    {Acc ++ Errors, NewValue}
            end;
        _ ->
            {Acc, FieldValue}
    end.

map_field(?MAP(_Name, Type), FieldSchema, Value, Opts) ->
    %% map type always has string keys
    Keys = maps_keys(unbox(Opts, Value)),
    FieldNames = [str(K) || K <- Keys],
    %% All objects in this map should share the same schema.
    NewSc = override(FieldSchema, #{type => Type, mapping => undefined}),
    NewFields = [{FieldName, NewSc} || FieldName <- FieldNames],
    do_map(NewFields, Value, Opts, NewSc); %% start over
map_field(?R_REF(Module, Ref), FieldSchema, Value, Opts) ->
    %% Switching to another module, good luck.
    do_map(Module:fields(Ref), Value, Opts#{schema := Module}, FieldSchema);
map_field(?REF(Ref), FieldSchema, Value, #{schema := Schema} = Opts) ->
    Fields = fields(Schema, Ref),
    do_map(Fields, Value, Opts, FieldSchema);
map_field(Ref, FieldSchema, Value, #{schema := Schema} = Opts) when is_list(Ref) ->
    Fields = fields(Schema, Ref),
    do_map(Fields, Value, Opts, FieldSchema);
map_field(?UNION(Types), Schema0, Value, Opts) ->
    %% union is not a boxed value
    F = fun(Type) ->
                %% go deep with union member's type, but all
                %% other schema information should be inherited from the enclosing schema
                Schema = sub_schema(Schema0, Type),
                map_field(Type, Schema, Value, Opts)
        end,
    case do_map_union(Types, F, #{}, Opts) of
        {ok, {Mapped, NewValue}} -> {Mapped, NewValue};
        Error -> {Error, Value}
    end;
map_field(?LAZY(Type), Schema, Value, Opts) ->
    SubType = sub_type(Schema, Type),
    case maps:get(check_lazy, Opts, false) of
        true -> map_field(SubType, Schema, Value, Opts);
        false -> {[], Value}
    end;
map_field(Type, Schema, Value0, Opts) ->
    map_field_0(Type, Schema, Value0, Opts, field_schema(Schema, converter)).

map_field_0(Type, Schema, Value0, Opts, undefined) ->
    map_field_1(Type, Schema, Value0, Opts);
map_field_0(Type, Schema, Value0, Opts, Converter) ->
    Value1 = plain_value(unbox(Opts, Value0), Opts),
    try Converter(Value1) of
        Value2 ->
            Value3 = maybe_mkrich(Opts, Value2, Value0),
            {Mapped, Value} = map_field_1(Type, Schema, Value3, Opts),
            case Opts of
                #{no_conversion := true} -> {Mapped, Value0};
                _ -> {Mapped, Value}
            end
    catch
        C : E : St ->
            {validation_errs(Opts, #{reason => converter_crashed,
                                     exception => {C, E},
                                     stacktrace => St
                                    }), Value0}
    end.

map_field_1(?ARRAY(Type), _Schema, Value0, Opts) ->
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
map_field_1(Type, Schema, Value0, Opts) ->
    %% primitive type
    Value = unbox(Opts, Value0),
    PlainValue = plain_value(Value, Opts),
    try hocon_schema_builtin:convert(PlainValue, Type) of
        ConvertedValue ->
            Validators = builtin_validators(Type),
            ValidationResult = validate(Opts, Schema, ConvertedValue, Validators),
            {ValidationResult, boxit(Opts, ConvertedValue, Value0)}
    catch
        C : E : St ->
            {validation_errs(Opts, #{reason => converter_crashed,
                                     exception => {C, E},
                                     stacktrace => St
                                     }), Value0}
    end.

sub_schema(EnclosingSchema, MaybeType) ->
    fun(type) -> field_schema(MaybeType, type);
       (Other) -> field_schema(EnclosingSchema, Other)
    end.

sub_type(EnclosingSchema, MaybeType) ->
    SubSc = sub_schema(EnclosingSchema, MaybeType),
    SubSc(type).

maps_keys(undefined) -> [];
maps_keys(Map) -> maps:keys(Map).

check_unknown_fields(Opts, SchemaFieldNames, DataFields) ->
    case find_unknown_fields(Opts, SchemaFieldNames, DataFields) of
        [] ->
            ok;
        Unknowns ->
            Err = #{reason => unknown_fields,
                    path => path(Opts),
                    expected => SchemaFieldNames,
                    unknown => Unknowns
                   },
            validation_errs(Opts, Err)
    end.

find_unknown_fields(_Opts, _SchemaFieldNames, undefined) -> [];
find_unknown_fields(Opts, SchemaFieldNames0, DataFields) ->
    SchemaFieldNames = lists:map(fun bin/1, SchemaFieldNames0),
    maps:fold(fun(DfName, DfValue, Acc) ->
                      case is_known_field(Opts, DfName, DfValue, SchemaFieldNames) of
                          true ->
                              Acc;
                          false ->
                              Unknown = case meta(DfValue) of
                                            undefined -> DfName;
                                            Meta -> {DfName, Meta}
                                        end,
                              [Unknown | Acc]
                      end
              end, [], DataFields).

is_known_field(Opts, Name, Value, ExpectedNames) ->
    is_known_name(Name, ExpectedNames) orelse
    case Value of
        #{?HOCON_V := ?FROM_ENV_VAR(EnvName, _)} ->
            log(Opts, warning, bin(["unknown_environment_variable_discarded: ", EnvName])),
            true;
        _ ->
            false
    end.

is_known_name(Name, ExpectedNames) ->
    lists:any(fun(N) -> N =:= bin(Name) end, ExpectedNames).

is_nullable(Opts, Schema) ->
    case field_schema(Schema, nullable) of
        undefined -> maps:get(nullable, Opts, ?DEFAULT_NULLABLE);
        Maybe -> Maybe
    end.

field_schema(Atom, type) when is_atom(Atom) -> Atom;
field_schema(Type, SchemaKey) when ?IS_TYPEREFL(Type) ->
    field_schema(hoconsc:mk(Type), SchemaKey);
field_schema(?MAP(_Name, _Type) = Map, SchemaKey) ->
    field_schema(hoconsc:mk(Map), SchemaKey);
field_schema(?LAZY(_) = Lazy, SchemaKey) ->
    field_schema(hoconsc:mk(Lazy), SchemaKey);
field_schema(Ref, SchemaKey) when is_list(Ref) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?REF(_) = Ref, SchemaKey) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?R_REF(_, _) = Ref, SchemaKey) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?ARRAY(_) = Array, SchemaKey) ->
    field_schema(hoconsc:mk(Array), SchemaKey);
field_schema(?UNION(_) = Union, SchemaKey) ->
    field_schema(hoconsc:mk(Union), SchemaKey);
field_schema(?ENUM(_) = Enum, SchemaKey) ->
    field_schema(hoconsc:mk(Enum), SchemaKey);
field_schema(FieldSchema, SchemaKey) when is_function(FieldSchema, 1) ->
    FieldSchema(SchemaKey);
field_schema(FieldSchema, SchemaKey) when is_map(FieldSchema) ->
    maps:get(SchemaKey, FieldSchema, undefined).

maybe_mapping(undefined, _) -> []; % no mapping defined for this field
maybe_mapping(_, undefined) -> []; % no value retrieved for this field
maybe_mapping(MappedPath, PlainValue) ->
    [{string:tokens(MappedPath, "."), PlainValue}].

push_stack(#{stack := Stack} = X, New) ->
    X#{stack := [New | Stack]};
push_stack(X, New) ->
    X#{stack => [New]}.

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
        {Name, EnvValue} ->
            maybe_mkrich(Opts, EnvValue, ?META_BOX(from_env, Name))
    end.

resolve_default_override(Schema, FieldValue, Opts) ->
    case unbox(Opts, FieldValue) of
        ?FROM_ENV_VAR(EnvName, EnvValue) ->
            log_env_override(Schema, Opts, EnvName, path(Opts), EnvValue),
            maybe_mkrich(Opts, EnvValue, ?META_BOX(from_env, EnvName));
        _ ->
            maybe_use_default(field_schema(Schema, default), FieldValue, Opts)
    end.

%% use default value if field value is 'undefined'
maybe_use_default(undefined, Value, _Opts) -> Value;
maybe_use_default(Default, undefined, Opts) ->
    maybe_mkrich(Opts, Default, ?META_BOX(made_for, default_value));
maybe_use_default(_, Value, _Opts) -> Value.

collect_envs(#{override_env := false}) -> {undefined, []};
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
            Msg = iolist_to_binary(io_lib:format("invalid_hocon_string: ~p, reason: ~p",
                      [Value, Reason])),
            log(Opts, debug, Msg),
            Value
    end.

apply_env(_Ns, [], _RootName, Conf, _Opts) -> Conf;
apply_env(Ns, [{VarName, V} | More], RootName, Conf, Opts) ->
    K = string:prefix(VarName, Ns),
    Path0 = string:split(string:lowercase(K), "__", all),
    Path1 = lists:filter(fun(N) -> N =/= [] end, Path0),
    NewConf = case Path1 =/= [] andalso bin(RootName) =:= bin(hd(Path1)) of
                  true ->
                      Path = string:join(Path1, "."),
                      %% It lacks schema info here, so we need to tag the value '$FROM_ENV_VAR'
                      %% and the value will be logged later when checking against schema
                      %% so we know if the value is sensitive or not.
                      %% NOTE: never translate to atom key here
                      put_value(Opts#{atom_key => false}, Path, ?FROM_ENV_VAR(VarName, V), Conf);
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
log(_Opts, Level, Msg) when is_binary(Msg) ->
    logger:log(Level, "~s", [Msg]);
log(_Opts, Level, Msg) ->
    logger:log(Level, Msg).

meta(#{?METADATA := M}) -> M;
meta(_) -> undefined.

unbox(_, undefined) -> undefined;
unbox(#{format := map}, Value) -> Value;
unbox(#{format := richmap}, Boxed) -> unbox(Boxed).

unbox(Boxed) ->
    case is_map(Boxed) andalso maps:is_key(?HOCON_V, Boxed) of
        true -> maps:get(?HOCON_V, Boxed);
        false -> error({bad_richmap, Boxed})
    end.

safe_unbox(MaybeBox) ->
    case maps:get(?HOCON_V, MaybeBox, undefined) of
        undefined -> #{};
        Value -> Value
    end.

boxit(#{format := map}, Value, _OldValue) -> Value;
boxit(#{format := richmap}, Value, undefined) -> boxit(Value, ?NULL_BOX);
boxit(#{format := richmap}, Value, Box) -> boxit(Value, Box).

boxit(Value, Box) -> Box#{?HOCON_V => Value}.

%% nested boxing
maybe_mkrich(#{format := map}, Value, _Box) ->
    Value;
maybe_mkrich(#{format := richmap}, Value, Box) ->
    hocon_util:deep_merge(mkrich(Value, Box), Box).

mkrich(Arr, Box) when is_list(Arr) ->
    NewArr = [mkrich(I, Box) || I <- Arr],
    boxit(NewArr, Box);
mkrich(Map, Box) when is_map(Map) ->
    boxit(maps:from_list(
            [{Name, mkrich(Value, Box)} || {Name, Value} <- maps:to_list(Map)]),
          Box);
mkrich(Val, Box) ->
    boxit(Val, Box).

get_field(#{format := richmap}, Path, Conf) -> deep_get(Path, Conf);
get_field(#{format := map}, Path, Conf) -> get_value(Path, Conf).

%% put (maybe deep) value to map/richmap
%% e.g. "path.to.my.value"
put_value(_Opts, _Path, undefined, Conf) ->
    Conf;
put_value(#{format := richmap} = Opts, Path, V, Conf) ->
    deep_put(Opts, Path, V, Conf);
put_value(#{format := map} = Opts, Path, V, Conf) ->
    plain_put(Opts, split(Path), V, Conf).

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
                    {str(Var), read_hocon_val(V, Opts)}
            end
    end.

validators(undefined) -> [];
validators(Validator) when is_function(Validator) ->
    validators([Validator]);
validators(Validators) when is_list(Validators) ->
    true = lists:all(fun(F) -> is_function(F, 1) end, Validators), %% assert
    Validators.

builtin_validators(?ENUM(Symbols)) ->
    [fun(Value) -> check_enum_sybol(Value, Symbols) end];
builtin_validators(Type) ->
    TypeChecker = fun (Value) -> typerefl:typecheck(Type, Value) end,
    [TypeChecker].

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
    Err = case meta(Value) of
              undefined -> #{reason => Reason, value => Value};
              Meta -> #{reason => Reason, value => richmap_to_map(Value), location => Meta}
          end,
    validation_errs(Opts, Err).

validation_errs(Opts, Context) ->
    [{error, ?VALIDATION_ERRS(Context#{path => path(Opts)})}].

plain_value(Value, #{format := map}) -> Value;
plain_value(Value, #{format := richmap}) -> richmap_to_map(Value).

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
    Value = maps:get(?HOCON_V, EnclosingMap),
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

-spec plain_put(opts(), [binary()], term(), hocon:confing()) -> hocon:config().
plain_put(_Opts, [], Value, _Old) -> Value;
plain_put(Opts, Path, Value, undefined) ->
    plain_put(Opts, Path, Value, #{});
plain_put(Opts, [Name | Path], Value, Conf) when is_map(Conf) ->
    FieldV = maps:get(Name, Conf, #{}),
    NewConf = maps:without([Name], Conf),
    NewFieldV = plain_put(Opts, Path, Value, FieldV),
    NewConf#{maybe_atom(Opts, Name) => NewFieldV}.

maybe_atom(#{atom_key := true}, Name) when is_binary(Name) ->
    try
        binary_to_existing_atom(Name, utf8)
    catch
        _ : _ ->
            error({non_existing_atom, Name})
    end;
maybe_atom(_Opts, Name) ->
    Name.

%% put unboxed value to the richmap box
%% this function is called places where there is no boxing context
%% so it has to accept unboxed value.
deep_put(Opts, Path, Value, Conf) ->
    put_rich(Opts, split(Path), Value, Conf).

put_rich(_Opts, [], Value, Box) ->
    boxit(Value, Box);
put_rich(Opts, [Name | Path], Value, Box) ->
    BoxV = safe_unbox(Box),
    FieldV = maps:get(Name, BoxV, #{}),
    NewFieldV = put_rich(Opts, Path, Value, FieldV),
    TmpBoxV = maps:without([Name], BoxV),
    NewBoxV = TmpBoxV#{maybe_atom(Opts, Name) => NewFieldV},
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
        {?METADATA, _, I} ->
            richmap_to_map(I, Map);
        {?HOCON_T, _, I} ->
            richmap_to_map(I, Map);
        {?HOCON_V, M, _} when is_map(M) ->
            richmap_to_map(maps:iterator(M), #{});
        {?HOCON_V, A, _} when is_list(A) ->
            [richmap_to_map(R) || R <- A];
        {?HOCON_V, V, _} ->
            V;
        {K, V, I} ->
            richmap_to_map(I, Map#{K => richmap_to_map(V)});
        none ->
            Map
    end.

%% treat 'null' as absence
drop_nulls(_Opts, undefined) -> undefined;
drop_nulls(Opts, Map) when is_map(Map) ->
    maps:filter(fun(_Key, Value) ->
                        case unbox(Opts, Value) of
                            null -> false;
                            {'$FROM_ENV_VAR', _, null} -> false;
                            _ -> true
                        end
                end, Map).

%% @doc Get (maybe nested) field value for the given path.
%% This function works for both plain and rich map,
%% And it always returns plain map.
-spec get_value(string(), hocon:config()) -> term().
get_value(Path, Conf) ->
    %% ensure plain map
    do_get(split(Path), richmap_to_map(Conf)).

do_get([], Conf) ->
    %% value as-is
    Conf;
do_get(_, undefined) ->
    undefined;
do_get([H | T], Conf) ->
    do_get(T, try_get(H, Conf)).

try_get(Key, Conf) when is_map(Conf) ->
    case maps:get(Key, Conf, undefined) of
        undefined ->
            try binary_to_existing_atom(Key, utf8) of
                AtomKey -> maps:get(AtomKey, Conf, undefined)
            catch
                error : badarg ->
                    undefined
            end;
        Value ->
            Value
    end;
try_get(Key, Conf) when is_list(Conf) ->
    try binary_to_integer(Key) of
        N ->
            lists:nth(N, Conf)
    catch
        error : badarg ->
            undefined
    end.


-spec get_value(string(), hocon:config(), term()) -> term().
get_value(Path, Config, Default) ->
    case get_value(Path, Config) of
        undefined -> Default;
        V -> V
    end.

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

find_structs(_Schema, [], Acc) -> Acc;
find_structs(Schema, [{_FieldName, FieldSchema} | Fields], Acc0) ->
    Type = hocon_schema:field_schema(FieldSchema, type),
    Acc = find_structs_per_type(Schema, Type, Acc0),
    find_structs(Schema, Fields, Acc).

find_structs_per_type(Schema, Name, Acc) when is_list(Name) ->
    find_ref(Schema, Name, Acc);
find_structs_per_type(Schema, ?REF(Name), Acc) ->
    find_ref(Schema, Name, Acc);
find_structs_per_type(_Schema, ?R_REF(Module, Name), Acc) ->
    find_ref(Module, Name, Acc);
find_structs_per_type(Schema, ?LAZY(Type), Acc) ->
    find_structs_per_type(Schema, Type, Acc);
find_structs_per_type(Schema, ?ARRAY(Type), Acc) ->
    find_structs_per_type(Schema, Type, Acc);
find_structs_per_type(Schema, ?UNION(Types), Acc) ->
    lists:foldl(fun(T, AccIn) ->
                        find_structs_per_type(Schema, T, AccIn)
                end, Acc, Types);
find_structs_per_type(Schema, ?MAP(_Name, Type), Acc) ->
    find_structs_per_type(Schema, Type, Acc);
find_structs_per_type(_Schema, _Type, Acc) ->
    Acc.

find_ref(Schema, Name, Acc) ->
    Namespace = hocon_schema:namespace(Schema),
    Key = {Namespace, Name},
    case maps:find(Key, Acc) of
        {ok, _} ->
            %% visted before, avoid duplication
            Acc;
        error ->
            Fields = hocon_schema:fields(Schema, Name),
            find_structs(Schema, Fields, Acc#{Key => Fields})
    end.
