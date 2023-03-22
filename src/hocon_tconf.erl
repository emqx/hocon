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

%% tconf: typed-config
-module(hocon_tconf).

-elvis([{elvis_style, god_modules, disable}]).

%% data validation and transformation
-export([map/2, map/3, map/4]).
-export([translate/3]).
-export([generate/2, generate/3, map_translate/3]).
-export([check/2, check/3, check_plain/2, check_plain/3, check_plain/4]).
-export([merge_env_overrides/4]).
-export([nest/1]).
-export([make_serializable/3]).

-include("hoconsc.hrl").
-include("hocon_private.hrl").

-export_type([opts/0]).

-type loggerfunc() :: fun((atom(), map()) -> ok).
%% Config map/check options.
-type opts() :: #{
    logger => loggerfunc(),
    obfuscate_sensitive_values => boolean(),
    atom_key => boolean(),
    return_plain => boolean(),
    %% apply environment variable overrides when
    %% apply_override_envs is set to true and also
    %% HOCON_ENV_OVERRIDE_PREFIX is set.
    %% default is true.
    apply_override_envs => boolean(),
    %% `required` is false by default, which allow all fields to be `undefined`.
    %% if `required` is set to `true`
    %% map or check APIs fail with validation_error
    %% when required field is not found or required field's value is `undefined`.
    %% NOTE: this option serves as default value for field's `required` spec

    %% default: false for map, true for check
    required => boolean(),

    %% below options are generated internally and should not be passed in by callers
    %%
    %% format converted values back to HOCON or JSON serializable map
    %% (with default value filled)
    make_serializable => boolean(),
    format => map | richmap,
    stack => [name()],
    schema => schema(),
    check_lazy => boolean()
}.

-type name() :: hocon_schema:name().
-type schema() :: hocon_schema:schema().

-define(VALIDATION_ERRS(Context), [Context#{kind => validation_error}]).
-define(TRANSLATION_ERRS(Context), [Context#{kind => translation_error}]).

-define(DEFAULT_REQUIRED, false).

-define(META_BOX(Tag, Metadata), #{?METADATA => #{Tag => Metadata}}).
-define(NULL_BOX, #{?METADATA => #{made_for => null_value}}).
-define(MAGIC, '$magic_chicken').
-define(MAGIC_SCHEMA, #{type => ?MAGIC}).
-define(MAP_KEY_RE, <<"^[A-Za-z0-9]+[A-Za-z0-9-_]*$">>).

%% @doc generates application env from a parsed .conf and a schema module.
%% For example, one can set the output values by
%%    lists:foreach(fun({AppName, Envs}) ->
%%        [application:set_env(AppName, Par, Val) || {Par, Val} <- Envs]
%%    end, hocon_schema_generate(Schema, Conf)).
-spec generate(schema(), hocon:config()) -> [proplists:property()].
generate(Schema, Conf) ->
    generate(Schema, Conf, #{}).

generate(Schema, Conf, Opts) ->
    {Mapped, _NewConf} = map_translate(Schema, Conf, Opts),
    Mapped.

-spec map_translate(schema(), hocon:config(), opts()) ->
    {[proplists:property()], hocon:config()}.
map_translate(Schema, Conf, Opts) ->
    {Mapped, NewConf} = map(Schema, Conf, all, Opts),
    Translated = translate(Schema, NewConf, Mapped),
    {nest(Translated), NewConf}.

%% @private returns a nested proplist with atom keys
-spec nest([proplists:property()]) -> [proplists:property()].
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
    case hocon_schema:translations(Schema) of
        [] ->
            Mapped;
        Namespaces ->
            Res = lists:append([
                do_translate(
                    hocon_schema:translation(Schema, N),
                    str(N),
                    Conf,
                    Mapped
                )
             || N <- Namespaces
            ]),
            ok = assert(Schema, Res),
            %% rm field if translation returns undefined
            [{K, V} || {K, V} <- lists:ukeymerge(1, Res, Mapped), V =/= undefined]
    end.

do_translate([], _Namespace, _Conf, Acc) ->
    Acc;
do_translate([{MappedField, Translator} | More], TrNamespace, Conf, Acc) ->
    MappedField0 = TrNamespace ++ "." ++ MappedField,
    try Translator(Conf) of
        Value ->
            do_translate(More, TrNamespace, Conf, [{string:tokens(MappedField0, "."), Value} | Acc])
    catch
        throw:Reason ->
            Error =
                {error,
                    ?TRANSLATION_ERRS(#{
                        reason => Reason,
                        path => MappedField0
                    })},
            do_translate(More, TrNamespace, Conf, [Error | Acc]);
        Exception:Reason:St ->
            Error =
                {error,
                    ?TRANSLATION_ERRS(#{
                        reason => Reason,
                        stacktrace => St,
                        path => MappedField0,
                        exception => Exception
                    })},
            do_translate(More, TrNamespace, Conf, [Error | Acc])
    end.

assert_integrity(Schema, Conf0, #{format := Format}) ->
    Conf =
        case Format of
            richmap -> ensure_plain(Conf0);
            map -> Conf0
        end,
    Names = hocon_schema:validations(Schema),
    Errors = assert_integrity(Schema, Names, Conf, []),
    ok = assert(Schema, Errors).

assert_integrity(_Schema, [], _Conf, Result) ->
    lists:reverse(Result);
assert_integrity(Schema, [{Name, Validator} | Rest], Conf, Acc) ->
    try Validator(Conf) of
        OK when OK =:= true orelse OK =:= ok ->
            assert_integrity(Schema, Rest, Conf, Acc);
        Other ->
            assert_integrity_failure(Schema, Rest, Conf, Name, Other)
    catch
        throw:Reason ->
            assert_integrity_failure(Schema, Rest, Conf, Name, Reason);
        Exception:Reason:St ->
            Error =
                {error,
                    ?VALIDATION_ERRS(#{
                        reason => integrity_validation_crash,
                        validation_name => Name,
                        exception => {Exception, Reason},
                        stacktrace => St
                    })},
            assert_integrity(Schema, Rest, Conf, [Error | Acc])
    end.

assert_integrity_failure(Schema, Rest, Conf, Name, Reason) ->
    assert_integrity(
        Schema,
        Rest,
        Conf,
        [
            {error,
                ?VALIDATION_ERRS(#{
                    reason => integrity_validation_failure,
                    validation_name => Name,
                    result => Reason
                })}
        ]
    ).

merge_opts(Default, Opts) ->
    maps:merge(
        Default#{
            apply_override_envs => false,
            atom_key => false
        },
        Opts
    ).

%% @doc Check richmap input against schema.
%% Returns a new config with:
%% 1) default values from schema if not found in input config
%% 2) environment variable overrides applied
-spec check(schema(), hocon:config()) -> hocon:config().
check(Schema, Conf) ->
    check(Schema, Conf, #{}).

check(Schema, Conf, Opts0) ->
    Opts = merge_opts(#{format => richmap}, Opts0),
    do_check(Schema, Conf, Opts, all).

%% @doc Check plain-map input against schema.
%% Returns a new config with:
%% 1) default values from schema if not found in input config
%% 2) environment variable overrides applied.
%% Returns a plain map (not richmap).
check_plain(Schema, Conf) ->
    check_plain(Schema, Conf, #{}).

check_plain(Schema, Conf, Opts0) ->
    Opts = merge_opts(#{format => map}, Opts0),
    check_plain(Schema, Conf, Opts, all).

check_plain(Schema, Conf, Opts0, RootNames) ->
    Opts = merge_opts(#{format => map}, Opts0),
    do_check(Schema, Conf, Opts, RootNames).

%% @doc Format a parsed (by converter) value back to HOCON or JSON
%% serializable map.
make_serializable(Schema, Conf, Opts) ->
    check_plain(Schema, Conf, Opts#{
        make_serializable => true,
        required => false,
        atom_key => false,
        apply_override_envs => false
    }).

do_check(Schema, Conf, Opts0, RootNames) ->
    Opts = merge_opts(#{required => true}, Opts0),
    %% discard mappings for check APIs
    {_DiscardMappings, NewConf} = map(Schema, Conf, RootNames, Opts),
    NewConf.

return_plain(Conf, #{return_plain := true}) ->
    ensure_plain(Conf);
return_plain(Conf, _) ->
    Conf.

-spec map(schema(), hocon:config()) -> {[proplists:property()], hocon:config()}.
map(Schema, Conf) ->
    Roots = [N || {N, _} <- hocon_schema:roots(Schema)],
    map(Schema, Conf, Roots, #{}).

-spec map(schema(), hocon:config(), all | [name()]) ->
    {[proplists:property()], hocon:config()}.
map(Schema, Conf, RootNames) ->
    map(Schema, Conf, RootNames, #{}).

-spec map(schema(), hocon:config(), all | [name()], opts()) ->
    {[proplists:property()], hocon:config()}.
map(Schema, Conf, all, Opts) ->
    map(Schema, Conf, hocon_schema:root_names(Schema), Opts);
map(Schema, Conf0, Roots0, Opts0) ->
    Opts = merge_opts(
        #{
            schema => Schema,
            format => richmap
        },
        Opts0
    ),
    Conf1 = ensure_format(Conf0, Opts),
    Roots = resolve_root_types(hocon_schema:roots(Schema), Roots0),
    Conf2 = filter_by_roots(Opts, Conf1, Roots),
    Conf3 = apply_envs(Schema, Conf2, Opts, Roots),
    {Mapped0, Conf4} = do_map(Roots, Conf3, Opts, ?MAGIC_SCHEMA),
    Mapped = log_and_drop_env_overrides(Opts, Mapped0),
    ok = assert(Schema, Mapped),
    ok = assert_integrity(Schema, Conf4, Opts),
    Conf = return_plain(Conf4, Opts),
    {Mapped, Conf}.

%% ensure the input map is as desired in options.
%% convert richmap to map if 'map' is wanted
%% crash with not_richmap error if plain map is given for 'richmap' option
ensure_format(Conf, #{format := richmap}) ->
    case hocon_maps:is_richmap(Conf) of
        true -> Conf;
        false -> error(not_richmap)
    end;
ensure_format(Conf, #{format := map}) ->
    hocon_maps:ensure_plain(Conf).

%% @doc Apply environment variable overrides on top of the given Conf0
merge_env_overrides(Schema, Conf0, all, Opts) ->
    merge_env_overrides(Schema, Conf0, hocon_schema:root_names(Schema), Opts);
merge_env_overrides(Schema, Conf0, Roots0, Opts0) ->
    %% force
    Opts = Opts0#{apply_override_envs => true},
    Roots = resolve_root_types(hocon_schema:roots(Schema), Roots0),
    Conf1 = filter_by_roots(Opts, Conf0, Roots),
    apply_envs(Schema, Conf1, Opts, Roots).

%% the config 'map' call returns env overrides in mapping
%% results, this function helps to drop them from  the list
%% and log the overrides
log_and_drop_env_overrides(_Opts, []) ->
    [];
log_and_drop_env_overrides(Opts, [#{hocon_env_var_name := _} = H | T]) ->
    _ = log(Opts, info, H),
    log_and_drop_env_overrides(Opts, T);
log_and_drop_env_overrides(Opts, [H | T]) ->
    [H | log_and_drop_env_overrides(Opts, T)].

%% Merge environment overrides into HOCON value before checking it against the schema.
apply_envs(_Schema, Conf, #{apply_override_envs := false}, _Roots) ->
    Conf;
apply_envs(Schema, Conf0, Opts, Roots) ->
    {EnvNamespace, Envs} = collect_envs(Schema, Opts, Roots),
    do_apply_envs(EnvNamespace, Envs, Opts, Roots, Conf0).

do_apply_envs(_EnvNamespace, _Envs, _Opts, [], Conf) ->
    Conf;
do_apply_envs(EnvNamespace, Envs, Opts, [{_, RootSc} = Root | Roots], Conf) ->
    ShouldApply =
        case field_schema(RootSc, type) of
            ?LAZY(_) -> maps:get(check_lazy, Opts, false);
            _ -> true
        end,
    RootNames = name_and_aliases(Root),
    NewConf =
        case ShouldApply of
            true -> apply_env(EnvNamespace, Envs, RootNames, Conf, Opts);
            false -> Conf
        end,
    do_apply_envs(EnvNamespace, Envs, Opts, Roots, NewConf).

%% silently drop unknown data (root level only)
filter_by_roots(Opts, Conf, Roots) ->
    Names = names_and_aliases(Roots),
    boxit(Opts, maps:with(Names, unbox(Opts, Conf)), Conf).

resolve_root_types(_Roots, []) ->
    [];
resolve_root_types(Roots, [Name | Rest]) ->
    case lists:keyfind(bin(Name), 1, Roots) of
        {_, {OrigName, Sc}} ->
            [{OrigName, Sc} | resolve_root_types(Roots, Rest)];
        false ->
            %% maybe a private struct which is not exposed in roots/0
            [{Name, hoconsc:ref(Name)} | resolve_root_types(Roots, Rest)]
    end.

str(A) when is_atom(A) -> str(atom_to_binary(A, utf8));
str(B) when is_binary(B) -> unicode:characters_to_list(B, utf8);
str(S) when is_list(S) -> S.

bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(S) -> unicode:characters_to_binary(S, utf8).

do_map(Fields, Value, Opts, ParentSchema) ->
    case unbox(Opts, Value) of
        undefined ->
            case is_required(Opts, ParentSchema) of
                true ->
                    {required_field_errs(Opts), undefined};
                false ->
                    do_map2(Fields, boxit(Opts, undefined, undefined), Opts);
                {false, recursively} ->
                    {[], boxit(Opts, undefined, undefined)}
            end;
        V when is_map(V) ->
            do_map2(Fields, Value, Opts);
        _ ->
            {validation_errs(Opts, bad_value_for_struct, Value), Value}
    end.

do_map2(Fields, Value0, Opts) ->
    SchemaFieldNames = names_and_aliases(Fields),
    DataFields0 = unbox(Opts, Value0),
    DataFields = drop_nulls(Opts, DataFields0),
    Value = boxit(Opts, DataFields, Value0),
    case check_unknown_fields(Opts, SchemaFieldNames, DataFields) of
        ok -> map_fields(Fields, Value, [], Opts);
        Errors -> {Errors, Value}
    end.

map_fields([], Conf, Mapped, _Opts) ->
    {Mapped, Conf};
map_fields([{_, FieldSchema} = Field | Fields], Conf0, Acc, Opts) ->
    case hocon_schema:is_deprecated(FieldSchema) of
        true ->
            Conf = del_value(Opts, name_and_aliases(Field), Conf0),
            map_fields(Fields, Conf, Acc, Opts);
        false ->
            map_fields_cont([Field | Fields], Conf0, Acc, Opts)
    end.

map_fields_cont([{_, FieldSchema} = Field | Fields], Conf0, Acc, Opts) ->
    FieldType = field_schema(FieldSchema, type),
    [FieldName | Aliases] = name_and_aliases(Field),
    FieldValue = get_field_value(Opts, [FieldName | Aliases], Conf0),
    NewOpts = push_stack(Opts, FieldName),
    {FAcc, FValue} =
        try
            map_one_field(FieldType, FieldSchema, FieldValue, NewOpts)
        catch
            %% there is no test coverage for these lines
            %% if this happens, it's a bug!
            C:#{reason := failed_to_check_field} = E:St ->
                erlang:raise(C, E, St);
            C:E:St ->
                Err = #{
                    reason => failed_to_check_field,
                    field => FieldName,
                    path =>
                        try
                            path(Opts)
                        catch
                            _:_ -> []
                        end,
                    exception => E
                },
                catch log(
                    Opts,
                    error,
                    bin(
                        io_lib:format(
                            "input-config:~n~p~n~p~n",
                            [FieldValue, Err]
                        )
                    )
                ),
                erlang:raise(C, Err, St)
        end,
    Conf1 = put_value(Opts, FieldName, unbox(Opts, FValue), Conf0),
    %% now drop all aliases
    %% it is allowed to have both old and new names provided in the config
    %% but the first match wins.
    Conf =
        case Conf1 of
            undefined ->
                undefined;
            _ ->
                maps:without(Aliases, Conf1)
        end,
    map_fields(Fields, Conf, FAcc ++ Acc, Opts).

map_one_field(FieldType, FieldSchema, FieldValue0, Opts) ->
    IsMakeSerializable = is_make_serializable(Opts),
    %% when making serializable, we do not use default value for hidden fields
    IsDefaultAllowed =
        case {IsMakeSerializable, hocon_schema:is_hidden(FieldSchema)} of
            {true, true} -> false;
            _ -> true
        end,
    {MaybeLog, FieldValue} = resolve_field_value(FieldSchema, FieldValue0, Opts, IsDefaultAllowed),
    Converter = upgrade_converter(field_schema(FieldSchema, converter)),
    {Acc0, NewValue} = map_field_maybe_convert(FieldType, FieldSchema, FieldValue, Opts, Converter),
    Acc = MaybeLog ++ Acc0,
    Validators =
        case IsMakeSerializable orelse is_primitive_type(FieldType) of
            true ->
                %% we do not validate serializable maps (assuming it's typechecked already)
                %% primitive values are already validated
                [];
            false ->
                %% otherwise validate using the schema defined callbacks
                user_defined_validators(FieldSchema)
        end,
    case find_errors(Acc) of
        ok ->
            Pv = ensure_plain(NewValue),
            ValidationResult = validate(Opts, FieldSchema, Pv, Validators),
            Mapping =
                case is_make_serializable(Opts) of
                    true -> undefined;
                    false -> field_schema(FieldSchema, mapping)
                end,
            case ValidationResult of
                [] ->
                    Mapped = maybe_mapping(Mapping, Pv),
                    {Acc ++ Mapped, NewValue};
                Errors ->
                    {Acc ++ Errors, NewValue}
            end;
        _ ->
            {Acc, FieldValue}
    end.

map_field_maybe_convert(Type, Schema, Value0, Opts, undefined) ->
    map_field(Type, Schema, Value0, Opts);
map_field_maybe_convert(Type, Schema, Value0, Opts, Converter) ->
    Value1 = ensure_plain(Value0),
    try Converter(Value1, Opts) of
        Value2 ->
            Box =
                case Value0 of
                    undefined ->
                        ?META_BOX(from_converter, Converter);
                    _ ->
                        Value0
                end,
            Value3 = maybe_mkrich(Opts, Value2, Box),
            {Mapped, Value4} = map_field(Type, Schema, Value3, Opts),
            {Mapped, ensure_obfuscate_sensitive(Opts, Schema, Value4)}
    catch
        throw:Reason ->
            {validation_errs(Opts, #{reason => Reason}), Value0};
        C:E:St ->
            {
                validation_errs(Opts, #{
                    reason => converter_crashed,
                    exception => {C, E},
                    stacktrace => St
                }),
                Value0
            }
    end.

map_field(?MAP(_Name, Type), FieldSchema, Value, Opts) ->
    %% map type always has string keys
    Keys = maps_keys(unbox(Opts, Value)),
    case [str(K) || K <- Keys] of
        [] ->
            {[], Value};
        FieldNames ->
            case get_invalid_name(FieldNames) of
                [] ->
                    %% All objects in this map should share the same schema.
                    NewSc = hocon_schema:override(
                        FieldSchema,
                        #{type => Type, mapping => undefined}
                    ),
                    NewFields = [{FieldName, NewSc} || FieldName <- FieldNames],
                    %% start over
                    do_map(NewFields, Value, Opts, NewSc);
                InvalidNames ->
                    Context =
                        #{
                            reason => invalid_map_key,
                            expected_data_type => ?MAP_KEY_RE,
                            got => InvalidNames
                        },
                    {validation_errs(Opts, Context), Value}
            end
    end;
map_field(?R_REF(Module, Ref), FieldSchema, Value, Opts) ->
    %% Switching to another module, good luck.
    do_map(hocon_schema:fields(Module, Ref), Value, Opts#{schema := Module}, FieldSchema);
map_field(?REF(Ref), FieldSchema, Value, #{schema := Schema} = Opts) ->
    Fields = hocon_schema:fields(Schema, Ref),
    do_map(Fields, Value, Opts, FieldSchema);
map_field(Ref, FieldSchema, Value, #{schema := Schema} = Opts) when is_list(Ref) ->
    Fields = hocon_schema:fields(Schema, Ref),
    do_map(Fields, Value, Opts, FieldSchema);
map_field(?UNION(Types0), Schema0, Value, Opts) ->
    try select_union_members(Types0, Value, Opts) of
        Types ->
            F = fun(Type) ->
                %% go deep with union member's type, but all
                %% other schema information should be inherited from the enclosing schema
                Schema = sub_schema(Schema0, Type),
                map_field(Type, Schema, Value, Opts)
            end,
            case do_map_union(Types, F, #{}, Opts) of
                {ok, {Mapped, NewValue}} -> {Mapped, NewValue};
                Errors -> {Errors, Value}
            end
    catch
        throw:Reason ->
            {validation_errs(Opts, Reason), Value}
    end;
map_field(?LAZY(Type), Schema, Value, Opts) ->
    SubType = sub_type(Schema, Type),
    case maps:get(check_lazy, Opts, false) of
        true -> map_field(SubType, Schema, Value, Opts);
        false -> {[], Value}
    end;
map_field(?ARRAY(Type), _Schema, Value0, Opts) ->
    %% array needs an unbox
    Array = unbox(Opts, Value0),
    F = fun(I, Elem) ->
        NewOpts = push_stack(Opts, integer_to_binary(I)),
        map_one_field(Type, Type, Elem, NewOpts)
    end,
    Do = fun(ArrayForSure) ->
        case do_map_array(F, ArrayForSure, [], 1, []) of
            {ok, {NewArray, Mapped}} ->
                %% assert
                true = is_list(NewArray),
                %% and we need to box it back
                {Mapped, boxit(Opts, NewArray, Value0)};
            {error, Reasons} ->
                {[{error, Reasons}], Value0}
        end
    end,
    case is_list(Array) of
        true ->
            Do(Array);
        false when Array =:= undefined ->
            {[], undefined};
        false when is_map(Array) ->
            case check_indexed_array(maps:to_list(Array)) of
                {ok, Arr} ->
                    Do(Arr);
                {error, Reason} ->
                    {validation_errs(Opts, Reason), Value0}
            end;
        false ->
            Reason = #{expected_data_type => array, got => type_hint(Array)},
            {validation_errs(Opts, Reason), Value0}
    end;
map_field(Type, Schema, Value0, Opts) ->
    %% primitive type
    Value = unbox(Opts, Value0),
    PlainValue = ensure_plain(Value),
    ConvertedValue = eval_builtin_converter(PlainValue, Type, Opts),
    Validators = get_validators(Schema, Type, Opts),
    ValidationResult = validate(Opts, Schema, ConvertedValue, Validators),
    Value1 = boxit(Opts, ConvertedValue, Value0),
    {ValidationResult, ensure_obfuscate_sensitive(Opts, Schema, Value1)}.

eval_builtin_converter(PlainValue, Type, Opts) ->
    case is_make_serializable(Opts) of
        true ->
            ensure_bin_str(PlainValue);
        false ->
            hocon_schema_builtin:convert(PlainValue, Type)
    end.

get_validators(Schema, Type, Opts) ->
    case is_make_serializable(Opts) of
        true ->
            [];
        false ->
            user_defined_validators(Schema) ++ builtin_validators(Type)
    end.

is_primitive_type(Type) when ?IS_TYPEREFL(Type) -> true;
is_primitive_type(Atom) when is_atom(Atom) -> true;
is_primitive_type(?ENUM(_)) -> true;
is_primitive_type(_) -> false.

sub_schema(EnclosingSchema, MaybeType) ->
    fun
        (type) -> field_schema(MaybeType, type);
        (Other) -> field_schema(EnclosingSchema, Other)
    end.

sub_type(EnclosingSchema, MaybeType) ->
    SubSc = sub_schema(EnclosingSchema, MaybeType),
    SubSc(type).

maps_keys(undefined) -> [];
maps_keys(Map) -> maps:keys(Map).

check_unknown_fields(_Opts, _SchemaFieldNames, undefined) ->
    ok;
check_unknown_fields(Opts, SchemaFieldNames, DataFields) ->
    case match_field_names(SchemaFieldNames, DataFields) of
        ok ->
            ok;
        {error, {Expected, Unknowns}} ->
            Err = #{
                reason => unknown_fields,
                path => path(Opts),
                unmatched => fmt_field_names(Expected),
                unknown => fmt_field_names(Unknowns)
            },
            validation_errs(Opts, Err)
    end.

match_field_names(SchemaFieldNames0, DataFields) ->
    SchemaFieldNames = lists:map(fun bin/1, SchemaFieldNames0),
    match_field_names(SchemaFieldNames, maps:to_list(DataFields), []).

match_field_names(_Expected, [], []) ->
    ok;
match_field_names(Expected, [], Unknowns) ->
    {error, {Expected, Unknowns}};
match_field_names(Expected, [{DfName, _DfValue} | Rest], Unknowns) ->
    case match_field_name(DfName, Expected) of
        {[], _} ->
            match_field_names(Expected, Rest, [DfName | Unknowns]);
        {[_], RestExpected} ->
            match_field_names(RestExpected, Rest, Unknowns)
    end.

match_field_name(Name, ExpectedNames) ->
    lists:partition(fun(N) -> bin(N) =:= bin(Name) end, ExpectedNames).

is_required(Opts, Schema) ->
    case field_schema(Schema, required) of
        undefined -> maps:get(required, Opts, ?DEFAULT_REQUIRED);
        Maybe -> Maybe
    end.

field_schema(Sc, Key) ->
    hocon_schema:field_schema(Sc, Key).

% no mapping defined for this field
maybe_mapping(undefined, _) -> [];
% no value retrieved for this field
maybe_mapping(_, undefined) -> [];
maybe_mapping(MappedPath, PlainValue) -> [{string:tokens(MappedPath, "."), PlainValue}].

push_stack(#{stack := Stack} = X, New) ->
    X#{stack := [New | Stack]};
push_stack(X, New) ->
    X#{stack => [New]}.

%% get type validation stack.
path(#{stack := Stack}) ->
    path(Stack);
path(Stack) when is_list(Stack) ->
    string:join(lists:reverse(lists:map(fun str/1, Stack)), ".").

select_union_members(Types, undefined, _Opts) ->
    %% This means the enclosing schema does not have a default value
    %% so the `undefined' is passed down as-is.
    %% If the enclosing schema is nullable (required=false),
    %% then the type check will pass against the very first union member
    [hd(hoconsc:union_members(Types))];
select_union_members(Types, _Value, _Opts) when is_list(Types) ->
    Types;
select_union_members(Types, Value, Opts) when is_function(Types) ->
    try
        %% assert non-empty list, otherwise it's a bug in schema provider module
        [_ | _] = Types({value, ensure_plain2(Value, Opts)})
    catch
        error:Reason:St ->
            %% only catch 'error' exceptions
            %% the schema selector should 'throw' (preferrably a map())
            %% if unexpected value is received
            throw({select_union_members, Reason, St})
    end.

do_map_union([], _TypeCheck, PerTypeResult, Opts) ->
    case maps:size(PerTypeResult) of
        1 ->
            [{ReadableType, Err}] = maps:to_list(PerTypeResult),
            validation_errs(Opts, ensure_type_path(Err, ReadableType));
        _ ->
            validation_errs(Opts, #{
                reason => matched_no_union_member,
                mismatches => PerTypeResult
            })
    end;
do_map_union([Type | Types], TypeCheck, PerTypeResult, Opts) ->
    {Mapped, Value} = TypeCheck(Type),
    case find_errors(Mapped) of
        ok ->
            {ok, {Mapped, Value}};
        {error, Reasons} ->
            do_map_union(
                Types,
                TypeCheck,
                PerTypeResult#{readable_type(Type) => maybe_hd(Reasons)},
                Opts
            )
    end.

do_map_array(_F, [], Elems, _Index, Acc) ->
    {ok, {lists:reverse(Elems), Acc}};
do_map_array(F, [Elem | Rest], Res, Index, Acc) ->
    {Mapped, NewElem} = F(Index, Elem),
    case find_errors(Mapped) of
        ok -> do_map_array(F, Rest, [NewElem | Res], Index + 1, Mapped ++ Acc);
        {error, Reasons} -> {error, Reasons}
    end.

resolve_field_value(Schema, FieldValue, Opts, IsDefaultAllowed) ->
    Meta = meta(FieldValue),
    case Meta of
        #{from_env := EnvName} ->
            {
                [env_override_for_log(Schema, EnvName, path(Opts), ensure_plain(FieldValue))],
                FieldValue
            };
        _ ->
            DefaultValue = field_schema(Schema, default),
            {[], maybe_use_default(DefaultValue, FieldValue, Opts, IsDefaultAllowed)}
    end.

maybe_use_default(Default, undefined, Opts, _IsDefaultAllowed = true) when Default =/= undefined ->
    maybe_mkrich(Opts, Default, ?META_BOX(made_for, default_value));
maybe_use_default(_, Value, _Opts, _IsUseDefault) ->
    Value.

collect_envs(Schema, Opts, Roots) ->
    Ns = hocon_util:env_prefix(_Default = undefined),
    case Ns of
        undefined -> {undefined, []};
        _ -> {Ns, lists:keysort(1, collect_envs(Schema, Ns, Opts, Roots))}
    end.

collect_envs(Schema, Ns, Opts, Roots) ->
    Pairs = [
        begin
            [Name, Value] = string:split(KV, "="),
            {Name, Value}
        end
     || KV <- os:getenv(), string:prefix(KV, Ns) =/= nomatch
    ],
    Envs = lists:map(
        fun({N, V}) ->
            {check_env(Schema, Roots, Ns, N), N, V}
        end,
        Pairs
    ),
    case [Name || {warn, Name, _} <- Envs] of
        [] ->
            ok;
        Names ->
            UnknownVars = lists:sort(Names),
            Msg = bin(io_lib:format("unknown_env_vars: ~p", [UnknownVars])),
            log(Opts, warning, Msg)
    end,
    [parse_env(Name, Value, Opts) || {keep, Name, Value} <- Envs].

%% return keep | warn | ignore for the given environment variable
check_env(Schema, Roots, Ns, EnvVarName) ->
    case env_name_to_path(Ns, EnvVarName) of
        false ->
            %% bad format
            ignore;
        [RootName | Path] ->
            case is_field(Roots, RootName) of
                {true, Type} ->
                    case is_path(Schema, Type, Path) of
                        true -> keep;
                        false -> warn
                    end;
                false ->
                    %% unknown root
                    ignore
            end
    end.

is_field([], _Name) ->
    false;
is_field([{_, FieldSc} = Field | Fields], Name) ->
    Names = name_and_aliases(Field),
    case lists:member(bin(Name), Names) of
        true ->
            Type = hocon_schema:field_schema(FieldSc, type),
            {true, Type};
        false ->
            is_field(Fields, Name)
    end.

is_path(_Schema, _Name, []) ->
    true;
is_path(Schema, Name, Path) when is_list(Name) ->
    is_path2(Schema, Name, Path);
is_path(Schema, ?REF(Name), Path) ->
    is_path2(Schema, Name, Path);
is_path(_Schema, ?R_REF(Module, Name), Path) ->
    is_path2(Module, Name, Path);
is_path(Schema, ?LAZY(Type), Path) ->
    is_path(Schema, Type, Path);
is_path(Schema, ?ARRAY(Type), [Name | Path]) ->
    case hocon_util:is_array_index(Name) of
        {true, _} -> is_path(Schema, Type, Path);
        false -> false
    end;
is_path(Schema, ?UNION(Types), Path) ->
    lists:any(fun(T) -> is_path(Schema, T, Path) end, hoconsc:union_members(Types));
is_path(Schema, ?MAP(_, Type), [_ | Path]) ->
    is_path(Schema, Type, Path);
is_path(_Schema, _Type, _Path) ->
    false.

is_path2(Schema, RefName, [Name | Path]) ->
    Fields = hocon_schema:fields(Schema, RefName),
    case is_field(Fields, Name) of
        {true, Type} -> is_path(Schema, Type, Path);
        false -> false
    end.

%% EMQX_FOO__BAR -> ["foo", "bar"]
env_name_to_path(Ns, VarName) ->
    K = string:prefix(VarName, Ns),
    Path0 = string:split(string:lowercase(K), "__", all),
    case lists:filter(fun(N) -> N =/= [] end, Path0) of
        [] -> false;
        Path -> Path
    end.

%% Try to parse HOCON values set in env vars like:
%%  EMQX_FOO__BAR=12
%%  EMQX_FOO__BAR="{a: b}"
%%  EMQX_FOO__BAR="[a, b]"
%%
%% Complex values have to be properly escape-quoted HOCON literals,
%%
%% for example:
%%
%%  * export EMQX_FOO__BAR="{\"#1\" = 2}",
%%    the struct field name has to be quoted
%%
%%  * export EMQX_FOO__BAR="[\"string\", \"array\", \"111\"]",
%%    the string array element '111' has to be wrapped in quotes
%%
%% Plain values are returned as-is, either the type cast (typrefl)
%% or converter should take care of them.
parse_env(Name, "", _Opts) ->
    {Name, <<"">>};
parse_env(Name, Value, Opts) ->
    BoxedVal = "fake_key=" ++ Value,
    case hocon:binary(BoxedVal, #{format => map}) of
        {ok, #{<<"fake_key">> := V}} ->
            {Name, V};
        {error, _Reason} ->
            log(Opts, debug, [Name, " is not a valid hocon value, using it as binary."]),
            {Name, list_to_binary(Value)}
    end.

apply_env(_Ns, [], _RootName, Conf, _Opts) ->
    Conf;
apply_env(Ns, [{VarName, V} | More], RootNames, Conf, Opts) ->
    %% match [_ | _] here because the name is already validated
    [_ | _] = Path0 = env_name_to_path(Ns, VarName),
    NewConf =
        case Path0 =/= [] andalso lists:member(bin(hd(Path0)), RootNames) of
            true ->
                Path = lists:flatten(string:join(Path0, ".")),
                do_apply_env(VarName, V, Path, Conf, Opts);
            false ->
                Conf
        end,
    apply_env(Ns, More, RootNames, NewConf, Opts).

do_apply_env(VarName, VarValue, Path, Conf, Opts) ->
    %% It lacks schema info here, so we need to tag the value with 'from_env' meta data
    %% and the value will be logged later when checking against schema
    %% so we know if the value is sensitive or not.
    %% NOTE: never translate to atom key here
    Value = maybe_mkrich(Opts, VarValue, ?META_BOX(from_env, VarName)),
    try
        put_value(Opts#{atom_key => false}, Path, Value, Conf)
    catch
        throw:{bad_array_index, Reason} ->
            Msg = ["bad_array_index from ", VarName, ", ", Reason],
            log(Opts, error, unicode:characters_to_binary(Msg, utf8)),
            error({bad_array_index, VarName})
    end.

env_override_for_log(Schema, Var, K, V0) ->
    V = obfuscate(Schema, ensure_plain(V0)),
    #{hocon_env_var_name => Var, path => K, value => V}.

ensure_obfuscate_sensitive(Opts, Schema, Val) ->
    case obfuscate_sensitive_values(Opts) of
        true ->
            UnboxVal = unbox(Opts, Val),
            UnboxVal1 = obfuscate(Schema, UnboxVal),
            boxit(Opts, UnboxVal1, Val);
        false ->
            Val
    end.

obfuscate(Schema, Value) ->
    case field_schema(Schema, sensitive) of
        true -> <<"******">>;
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

boxit(#{format := map}, Value, _OldValue) -> Value;
boxit(#{format := richmap}, Value, undefined) -> boxit(Value, ?NULL_BOX);
boxit(#{format := richmap}, Value, Box) -> boxit(Value, Box).

boxit(Value, Box) -> Box#{?HOCON_V => Value}.

%% nested boxing
maybe_mkrich(_, undefined, _Box) ->
    undefined;
maybe_mkrich(#{format := map}, Value, _Box) ->
    Value;
maybe_mkrich(#{format := richmap}, Value, Box) ->
    hocon_maps:deep_merge(Box, mkrich(Value, Box)).

mkrich(Arr, Box) when is_list(Arr) ->
    NewArr = [mkrich(I, Box) || I <- Arr],
    boxit(NewArr, Box);
mkrich(Map, Box) when is_map(Map) ->
    boxit(
        maps:from_list(
            [{Name, mkrich(Value, Box)} || {Name, Value} <- maps:to_list(Map)]
        ),
        Box
    );
mkrich(Val, Box) ->
    boxit(Val, Box).

get_field_value(_, [], _Conf) ->
    undefined;
get_field_value(Opts, [Path | Rest], Conf) ->
    case do_get_field_value(Opts, Path, Conf) of
        undefined ->
            get_field_value(Opts, Rest, Conf);
        Value ->
            Value
    end.

do_get_field_value(#{format := richmap}, Path, Conf) ->
    hocon_maps:deep_get(Path, Conf);
do_get_field_value(#{format := map}, Path, Conf) ->
    hocon_maps:get(Path, ensure_plain(Conf)).

%% put (maybe deep) value to map/richmap
%% e.g. "path.to.my.value"
put_value(_Opts, _Path, undefined, Conf) ->
    Conf;
put_value(#{format := richmap} = Opts, Path, V, Conf) ->
    hocon_maps:deep_put(Path, V, Conf, Opts);
put_value(#{format := map} = Opts, Path, V, Conf) ->
    plain_put(Opts, split(Path), V, Conf).

del_value(Opts, Names, Conf) ->
    case unbox(Opts, Conf) of
        undefined ->
            Conf;
        V ->
            boxit(Opts, maps:without(Names, V), Conf)
    end.

split(Path) -> hocon_util:split_path(Path).

validators(undefined) ->
    [];
validators(Validator) when is_function(Validator) ->
    validators([Validator]);
validators(Validators) when is_list(Validators) ->
    %% assert
    true = lists:all(fun(F) -> is_function(F, 1) end, Validators),
    Validators.

user_defined_validators(Schema) ->
    validators(field_schema(Schema, validator)).

builtin_validators(?ENUM(Symbols)) ->
    [fun(Value) -> check_enum_sybol(Value, Symbols) end];
builtin_validators(Type) ->
    TypeChecker = fun(Value) ->
        case typerefl:typecheck(Type, Value) of
            ok ->
                ok;
            {error, _Reason} ->
                %% discard typerefl reason because it contains the actual value
                %% which could potentially be sensitive (hence need obfuscation)
                {error, #{expected_type => readable_type(Type)}}
        end
    end,
    [TypeChecker].

check_enum_sybol(Value, Symbols) when is_atom(Value); is_integer(Value) ->
    case lists:member(Value, Symbols) of
        true -> ok;
        false -> {error, not_a_enum_symbol}
    end;
check_enum_sybol(_Value, _Symbols) ->
    {error, unable_to_convert_to_enum_symbol}.

validate(Opts, Schema, Value, Validators) ->
    validate(Opts, Schema, Value, is_required(Opts, Schema), Validators).

validate(_Opts, _Schema, undefined, false, _Validators) ->
    % do not validate if no value is set
    [];
validate(Opts, _Schema, undefined, true, _Validators) ->
    required_field_errs(Opts);
validate(Opts, Schema, Value, _IsRequired, Validators) ->
    do_validate(Opts, Schema, Value, Validators).

%% returns on the first failure
do_validate(_Opts, _Schema, _Value, []) ->
    [];
do_validate(Opts, Schema, Value, [H | T]) ->
    try H(Value) of
        OK when OK =:= ok orelse OK =:= true ->
            do_validate(Opts, Schema, Value, T);
        false ->
            validation_errs(Opts, returned_false, obfuscate(Schema, Value));
        {error, Reason} ->
            validation_errs(Opts, Reason, obfuscate(Schema, Value))
    catch
        throw:Reason ->
            validation_errs(Opts, Reason, obfuscate(Schema, Value));
        C:E:St ->
            validation_errs(
                Opts,
                #{
                    exception => {C, E},
                    stacktrace => St
                },
                obfuscate(Schema, Value)
            )
    end.

required_field_errs(Opts) ->
    validation_errs(Opts, #{reason => required_field}).

validation_errs(Opts, Reason, Value) ->
    Err =
        case meta(Value) of
            undefined -> #{reason => Reason, value => Value};
            Meta -> #{reason => Reason, value => ensure_plain(Value), location => Meta}
        end,
    validation_errs(Opts, Err).

validation_errs(Opts, Context) ->
    ContextWithPath = ensure_path(Opts, Context),
    [{error, ?VALIDATION_ERRS(ContextWithPath)}].

ensure_path(_Opts, #{path := _} = Context) -> Context;
ensure_path(Opts, Context) -> Context#{path => path(Opts)}.

-spec plain_put(opts(), [binary()], term(), hocon:confing()) -> hocon:config().
plain_put(_Opts, [], Value, _Old) ->
    Value;
plain_put(Opts, [Name | Path], Value, Conf0) ->
    GoDeep = fun(V) -> plain_put(Opts, Path, Value, V) end,
    hocon_maps:do_put(Conf0, Name, GoDeep, Opts).

%% maybe secret, do not hint value
type_hint(B) when is_binary(B) -> string;
type_hint(X) -> X.

%% smart unboxing, it checks the top level box, if it's boxed, unbox recursively.
%% otherwise do nothing.
ensure_plain(MaybeRichMap) ->
    hocon_maps:ensure_plain(MaybeRichMap).

%% the top level value might be unboxed, so it needs the help from the format option.
%% if the format is richmap, it perform the not-so-smart recursive unboxing
ensure_plain2(Map, #{format := richmap}) ->
    hocon_util:richmap_to_map(Map);
ensure_plain2(Map, _) ->
    Map.

%% treat 'null' as absence
drop_nulls(_Opts, undefined) ->
    undefined;
drop_nulls(Opts, Map) when is_map(Map) ->
    maps:filter(
        fun(_Key, Value) ->
            case unbox(Opts, Value) of
                null -> false;
                _ -> true
            end
        end,
        Map
    ).

assert(Schema, List) ->
    case find_errors(List) of
        ok ->
            ok;
        {error, Reasons} ->
            true = lists:all(fun erlang:is_map/1, Reasons),
            throw({Schema, Reasons})
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

is_make_serializable(#{make_serializable := true}) -> true;
is_make_serializable(_) -> false.

upgrade_converter(undefined) ->
    undefined;
upgrade_converter(F) ->
    case erlang:fun_info(F, arity) of
        {_, 1} -> fun(V, Opts) -> eval_arity1_converter(F, V, Opts) end;
        {_, 2} -> F
    end.

eval_arity1_converter(F, V, Opts) ->
    case is_make_serializable(Opts) of
        true ->
            %% the old version convert is only one way
            %% we can only hope V is serializable
            V;
        false ->
            F(V)
    end.

obfuscate_sensitive_values(#{obfuscate_sensitive_values := true}) -> true;
obfuscate_sensitive_values(_) -> false.

ensure_bin_str(Value) when is_list(Value) ->
    case io_lib:printable_unicode_list(Value) of
        true -> unicode:characters_to_binary(Value, utf8);
        false -> Value
    end;
ensure_bin_str(Value) ->
    Value.

check_indexed_array(List) ->
    case check_indexed_array(List, [], []) of
        {Good, []} -> check_index_seq(1, lists:keysort(1, Good), []);
        {_, Bad} -> {error, #{bad_array_index_keys => Bad}}
    end.

check_indexed_array([], Good, Bad) ->
    {Good, Bad};
check_indexed_array([{I, V} | Rest], Good, Bad) ->
    case hocon_util:is_array_index(I) of
        {true, Index} -> check_indexed_array(Rest, [{Index, V} | Good], Bad);
        false -> check_indexed_array(Rest, Good, [I | Bad])
    end.

check_index_seq(_, [], Acc) ->
    {ok, lists:reverse(Acc)};
check_index_seq(I, [{Index, V} | Rest], Acc) ->
    case I =:= Index of
        true ->
            check_index_seq(I + 1, Rest, [V | Acc]);
        false ->
            {error, #{
                expected_index => I,
                got_index => Index
            }}
    end.

get_invalid_name(Names) ->
    lists:filter(
        fun(F) ->
            nomatch =:=
                try
                    re:run(F, ?MAP_KEY_RE)
                catch
                    _:_ -> nomatch
                end
        end,
        Names
    ).

fmt_field_names(Names) ->
    do_fmt_field_names(lists:sort(lists:map(fun str/1, Names))).

do_fmt_field_names([]) -> none;
do_fmt_field_names([Name1]) -> Name1;
do_fmt_field_names([Name1, Name2]) -> Name1 ++ "," ++ Name2;
do_fmt_field_names([Name1, Name2 | _]) -> do_fmt_field_names([Name1, Name2]) ++ ",...".

maybe_hd([OnlyOne]) -> OnlyOne;
maybe_hd(Other) -> Other.

readable_type(T) ->
    str(hocon_schema:readable_type(T)).

ensure_type_path(#{matched_type := SubType} = ErrorContext, ReadableType) ->
    ErrorContext#{matched_type => ReadableType ++ "/" ++ SubType};
ensure_type_path(ErrorContext, ReadableType) when is_map(ErrorContext) ->
    ErrorContext#{matched_type => ReadableType};
ensure_type_path(Errors, ReadableType) ->
    #{
        matched_type => ReadableType,
        errors => Errors
    }.

names_and_aliases(Fields) ->
    hocon_schema:names_and_aliases(Fields).

name_and_aliases(Field) ->
    hocon_schema:name_and_aliases(Field).
