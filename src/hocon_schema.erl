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

-export([map/2, translate/3, generate/2]).
-export([deep_get/3, deep_get/4]).

-export_type([ name/0
             , typefunc/0
             , translationfunc/0
             , schema/0]).

-type name() :: atom() | string().
-type typefunc() :: fun((_) -> _).
-type translationfunc() :: fun((hocon:config()) -> hocon:config()).
-type field() :: {name(), typefunc()}.
-type translation() :: {name(), translationfunc()}.
-type schema() :: module()
                | #{ structs := [name()]
                   , fileds := fun((name()) -> [field()])
                   , translations => [name()]
                   , translation => fun((name()) -> [translation()])
                   }.

-callback structs() -> [name()].
-callback fields(name()) -> [field()].
-callback translations() -> [name()].
-callback translation(name()) -> [translation()].

-optional_callbacks([translations/0, translation/1]).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% behaviour APIs
-spec structs(schema()) -> [name()].
structs(Mod) when is_atom(Mod) -> Mod:structs();
structs(#{structs := Names}) -> Names.

-spec fields(schema(), name()) -> [field()].
fields(Mod, Name) when is_atom(Mod) -> Mod:fields(Name);
fields(#{fields := F}, Name) -> F(Name).

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

-spec(translate(schema(), hocon:config(), [proplists:property()]) -> [proplists:property()]).
translate(Schema, Conf, Mapped) ->
    case translations(Schema) of
        [] -> Mapped;
        Namespaces ->
            Res = lists:append([do_translate(translation(Schema, N), str(N), Conf, Mapped) ||
                        N <- Namespaces]),
            ok = find_error(Res),
            %% rm field if translation returns undefined
            [{K, V} || {K, V} <- lists:ukeymerge(1, Res, Mapped), V =/= undefined]
    end.

do_translate([], _Namespace, _Conf, Acc) ->
    Acc;
do_translate([{MappedField, Translator} | More], Namespace, Conf, Acc) ->
    MappedField0 = Namespace ++ "." ++ MappedField,
    try
        do_translate(More, Namespace, Conf,
                     [{string:tokens(MappedField0, "."), Translator(Conf)} | Acc])
    catch
        _:Reason:St ->
            Error = {error, {translation_error, Reason, St, MappedField0}},
            do_translate(More, Namespace, Conf, [Error | Acc])
    end.

-spec(map(schema(), hocon:config()) -> {[proplists:property()], hocon:config()}).
map(Schema, RichMap) ->
    Namespaces = structs(Schema),
    F = fun (Namespace, {Acc, Conf}) ->
        {Mapped, NewConf} = do_map(fields(Schema, Namespace), str(Namespace), Conf, [], Schema),
        {lists:append(Acc, Mapped), NewConf} end,
    {Mapped, RichMap0} = lists:foldl(F, {[], RichMap}, Namespaces),
    ok = find_error(Mapped),
    {Mapped, RichMap0}.

str(A) when is_atom(A) -> atom_to_list(A);
str(S) -> S.

do_map([], _Namespace, RichMap, Acc, _Schema) ->
    {Acc, RichMap};
% wildcard
do_map([{[$$ | _], SchemaFun}], Namespace, Conf, Acc, SchemaModule) ->
    Fields = [binary_to_list(K) || K <- maps:keys(deep_get(Namespace, Conf, value, #{}))],
    do_map([{F, SchemaFun} || F <- Fields], Namespace, Conf, Acc, SchemaModule);
do_map([Field | More], Namespace, Conf, Acc, SchemaModule) ->
    {AbsField, SchemaFun} = case Field of
                                {Name, Func} ->
                                    {Namespace ++ "." ++ str(Name), Func};
                                Func ->
                                    {Namespace, Func}
                            end,
    ConfWithEnv = apply_env(SchemaFun, AbsField, Conf),
    % metadata inside array is lost here
    ValueWithEnv = resolve_array(deep_get(AbsField, ConfWithEnv, value)),
    ValueWithDefault = apply_default(SchemaFun, ValueWithEnv),
    ConvertedValue = apply_converter(SchemaFun, ValueWithDefault),
    {RefAcc, RefResolvedValue} = ref(SchemaFun(type), ConvertedValue, Namespace, SchemaModule),
    Validators = add_default_validator(SchemaFun(validator), SchemaFun(type), SchemaModule),
    RefResolvedConf = deep_put(AbsField, RefResolvedValue, Conf, value),
    ValidatedValue = validate(RefResolvedValue, Validators, AbsField, RefResolvedConf),
    NewAcc = case {SchemaFun(mapping), ValidatedValue} of
        {_, {error, _} = E} -> RefAcc ++ [E | Acc];
        {M, V} when M =/= undefined andalso V =/= undefined ->
            RefAcc ++ [{string:tokens(M, "."), richmap_to_map(V)} | Acc];
        _ -> RefAcc ++ Acc % skip if no mapping / the value is undefined
        end,
    do_map(More, Namespace, RefResolvedConf, NewAcc, SchemaModule).

-spec(apply_env(typefunc(), string(), hocon:config()) -> hocon:config()).
apply_env(TypeFunc, Field, Conf) ->
    Prefix = os:getenv("HOCON_ENV_OVERRIDE_PREFIX", ""),
    Key = Prefix ++ string:join(string:replace(string:uppercase(Field), ".", "__", all), ""),
    OverrideKey = case TypeFunc(override_env) of
                      undefined ->
                          "";
                      Sth ->
                          Prefix ++ Sth
                  end,
    case {os:getenv(Key), os:getenv(OverrideKey)} of
        {false, false} ->
            Conf;
        {V0, false} ->
            deep_put(Field, string_to_hocon(V0), Conf, value);
        {_, V1} ->
            deep_put(Field, string_to_hocon(V1), Conf, value)
    end.

-spec(apply_default(typefunc(), term()) -> term()).
apply_default(TypeFunc, undefined) ->
    TypeFunc(default);
apply_default(_, Value) ->
    Value.

-spec(ref(string() | typefunc(), hocon:config(), string(), schema()) ->
      {[proplists:property()], hocon:config() | undefined}).
ref(Ref, undefined, Namespace, Schema) when is_list(Ref) ->
    ref(Ref, #{}, Namespace, Schema);
ref(_, undefined, _, _) ->
    {[], undefined};
ref(Ref, Conf, _, Schema) when is_list(Ref) ->
    {Acc, #{value := NewConf}} = do_map(Schema:fields(Ref), "", #{value => Conf}, [], Schema),
    case [V || V <- maps:values(NewConf), #{value => undefined} =/= V] of
        [] ->
            {[], undefined};
        _ ->
            {Acc, NewConf}
    end;
ref(_, Value, _, _) ->
    {[], Value}.

string_to_hocon(Str) when is_list(Str) ->
    {ok, RichMap} = hocon:binary("key = " ++ Str, #{format => richmap}),
    deep_get("key", RichMap, value).

-spec(apply_converter(typefunc(), term()) -> term()).
apply_converter(SchemaFun, Value) ->
    case SchemaFun(converter) of
        undefined ->
            hocon_schema_builtin:convert(Value, SchemaFun(type));
        Converter ->
            try
                Converter(Value)
            catch
                _:_ -> Value
            end
    end.

add_default_validator(undefined, Type, Schema) ->
    add_default_validator([], Type, Schema);
add_default_validator(Validator, Type, Schema) when is_function(Validator) ->
    add_default_validator([Validator], Type, Schema);
add_default_validator(Validators, Struct, _Schema) when is_list(Struct) ->
    Validators;
add_default_validator(Validators, Type, _Schema) ->
    TypeChecker = fun (Value) -> typerefl:typecheck(Type, Value) end,
    [TypeChecker | Validators].

validate(undefined, _, _, _) ->
    undefined; % do not validate if no value is set
validate(Value, [], _, _) ->
    Value;
validate(Value, [H | T], Field, Conf) ->
    case H(Value) of
        ok ->
            validate(Value, T, Field, Conf);
        {error, Reason} ->
            {error, {validation_error, Reason, Field, deep_get(Field, Conf, all)}}
    end.

%% @doc get a child from richmap.
%% Key (first arg) can be "foo.bar.baz" or ["foo.bar", "baz"] or ["foo", "bar", "baz"].
%% if Param (third arg) is `all`, returns a child richmap.
-spec(deep_get(string() | [string()], hocon:config(), atom()) -> hocon:config() | undefined).
deep_get([], Conf, all) ->
    Conf;
deep_get([], Conf, Param) ->
    maps:get(Param, Conf);
deep_get([H | T], Conf, Param) when is_list(H) ->
    {NewH, NewT} = retokenize(H, T),
    Value = case maps:get(value, Conf, undefined) of
            undefined -> #{};
            Sth -> Sth
        end,
    case maps:get(list_to_binary(NewH), Value, undefined) of
        undefined ->
            undefined;
        ChildConf ->
            deep_get(NewT, ChildConf, Param)
    end;
deep_get(Str, RichMap, Param) when is_list(Str) ->
    deep_get(string:tokens(Str, "."), RichMap, Param).

deep_get(Str, RichMap, Param, Default) ->
    case deep_get(Str, RichMap, Param) of
        undefined ->
            Default;
        V ->
            V
    end.

%% @doc put a value to the child richmap.
-spec(deep_put(string() | [string()], term(), hocon:config(), atom()) -> hocon:config()).
deep_put([H | _T] = L, Value, RichMap, Param) when is_list(H) ->
    hocon_util:do_deep_merge(RichMap, #{value => nested_richmap(L, Value, Param)});
deep_put(Str, Value, RichMap, Param) when is_list(Str) ->
    deep_put(string:tokens(Str, "."), Value, RichMap, Param).

nested_richmap([H], Value, Param) ->
    case retokenize(H, []) of
        {H, []} ->
            #{list_to_binary(H) => #{Param => Value}};
        {NewH, NewT} ->
            #{list_to_binary(NewH) => #{value => nested_richmap(NewT, Value, Param)}}
    end;
nested_richmap([H | T], Value, Param) ->
    {NewH, NewT} = retokenize(H, T),
    #{list_to_binary(NewH) => #{value => nested_richmap(NewT, Value, Param)}}.

retokenize(H, T) ->
    case string:tokens(H, ".") of
        [H] ->
            {H, T};
        [Token | More] ->
            {Token, More ++ T}
    end.

resolve_array(ArrayOfRichMap) when is_list(ArrayOfRichMap) ->
    [richmap_to_map(R) || R <- ArrayOfRichMap];
resolve_array(Other) ->
    Other.

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

find_error(Proplist) ->
    case do_find_error(Proplist, []) of
        [{validation_error, _, _, _} | _] = Errors ->
            validation_error(Errors);
        [{translation_error, _, _, _} | _] = Errors ->
            translation_error(Errors);
        [] ->
            ok
    end.
do_find_error([], Res) ->
    Res;
do_find_error([{error, E} | More], Errors) ->
    do_find_error(More, [E | Errors]);
do_find_error([_ | More], Errors) ->
    do_find_error(More, Errors).

validation_error(Errors) ->
    F = fun ({validation_error, Reason, Field, M}, Acc) ->
        case hocon:filename_of(M) of
            undefined ->
                Acc ++ io_lib:format("validation_failed: ~p = ~p at_line ~p,~n~s~n",
                       [Field,
                        richmap_to_map(hocon:value_of(M)),
                        hocon:line_of(M),
                        Reason]);
            F ->
                Acc ++ io_lib:format("validation_failed: ~p = ~p " ++
                                     "in_file ~p at_line ~p,~n~s~n",
                       [Field,
                        richmap_to_map(hocon:value_of(M)),
                        F,
                        hocon:line_of(M),
                        Reason])
        end
    end,
    ErrorInfo = lists:foldl(F, "", Errors),
    throw({validation_error, iolist_to_binary(ErrorInfo)}).

translation_error(Errors) ->
    F = fun ({translation_error, Reason, St, MappedField}, Acc) ->
                Acc ++ io_lib:format("translation_failed: ~p,~n~p~n~p~n",
                    [MappedField, Reason, lists:sublist(St, 5)])
        end,
    ErrorInfo = lists:foldl(F, "", Errors),
    throw({translation_error, iolist_to_binary(ErrorInfo)}).


-ifdef(TEST).

deep_get_test_() ->
    F = fun(Str, Key, Param) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                                deep_get(Key, M, Param) end,
    [ ?_assertEqual(1, F("a=1", "a", value))
    , ?_assertMatch(#{line := 1}, F("a=1", "a", metadata))
    , ?_assertEqual(1, F("a={b=1}", "a.b", value))
    , ?_assertEqual(1, F("a={b=1}", ["a", "b"], value))
    , ?_assertEqual(undefined, F("a={b=1}", "a.c", value))
    ].

deep_put_test_() ->
    F = fun(Str, Key, Value, Param) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                                       NewM = deep_put(Key, Value, M, Param),
                                       deep_get(Key, NewM, Param) end,
    [ ?_assertEqual(2, F("a=1", "a", 2, value))
    , ?_assertEqual(2, F("a={b=1}", "a.b", 2, value))
    , ?_assertEqual(#{x => 1}, F("a={b=1}", "a.b", #{x => 1}, value))
    ].

richmap_to_map_test_() ->
    F = fun(Str) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                    richmap_to_map(M) end,
    [ ?_assertEqual(#{<<"a">> => #{<<"b">> => 1}}, F("a.b=1"))
    , ?_assertEqual(#{<<"a">> => #{<<"b">> => [1, 2, 3]}}, F("a.b = [1,2,3]"))
    , ?_assertEqual(#{<<"a">> =>
                      #{<<"b">> => [1, 2, #{<<"x">> => <<"foo">>}]}}, F("a.b = [1,2,{x=foo}]"))
    ].


mapping_test_() ->
    F = fun (Str) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                     {Mapped, _} = map(demo_schema, M),
                     Mapped end,
    [ ?_assertEqual([{["id"], 123}], F("id=123"))
    , ?_assertEqual([{["person", "id"], 123}], F("person.id=123"))
    , ?_assertEqual([{["app_foo", "setting"], "hello"}], F("foo.setting=hello"))
    , ?_assertEqual([{["app_foo", "setting"], "1"}], F("foo.setting=1"))
    , ?_assertThrow({validation_error,
        <<"validation_failed: \"foo.setting\" = [<<\"a\">>,<<\"b\">>,<<\"c\">>] at_line 1,\n"
          "Expected type: string() when\n"
          "  string() :: [char()].\n"
          "Got: [<<\"a\">>,<<\"b\">>,<<\"c\">>]\n\n">>}, F("foo.setting=[a,b,c]"))
    , ?_assertEqual([{["app_foo", "endpoint"], {127, 0, 0, 1}}], F("foo.endpoint=\"127.0.0.1\""))
    , ?_assertThrow({validation_error, _}, F("foo.setting=hi, foo.endpoint=hi"))
    , ?_assertThrow({validation_error, _},
        F("foo.greet=foo"))
    , ?_assertEqual([{["app_foo", "numbers"], [1, 2, 3]}], F("foo.numbers=[1,2,3]"))
    , ?_assertEqual([{["a", "b", "some_int"], 1}], F("a.b.some_int=1"))
    , ?_assertEqual([], F("foo.ref_x_y={some_int = 1}"))
    , ?_assertThrow({validation_error, _},
        F("foo.ref_x_y={some_int = aaa}"))
    , ?_assertEqual([],
        F("foo.ref_x_y={some_dur = 5s}"))
    , ?_assertEqual([{["app_foo", "refjk"], #{<<"some_int">> => 1}}],
                    F("foo.ref_j_k={some_int = 1}"))
    , ?_assertThrow({validation_error, _},
        F("foo.greet=foo\n foo.endpoint=hi"))
    ].

env_test_() ->
    F = fun (Str, Envs) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                           {Mapped, _} = with_envs(fun map/2, [demo_schema, M],
                                     Envs ++ [{"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}]),
                           Mapped end,
    [ ?_assertEqual([{["app_foo", "setting"], "hi"}],
                    F("foo.setting=hello", [{"EMQX_FOO__SETTING", "hi"}]))
    , ?_assertEqual([{["app_foo", "setting"], "yo"}],
                    F("foo.setting=hello", [{"EMQX_MY_OVERRIDE", "yo"}]))
    , ?_assertEqual([{["app_foo", "numbers"], [4, 5, 6]}],
                    F("foo.numbers=[1,2,3]", [{"EMQX_FOO__NUMBERS", "[4,5,6]"}]))
    , ?_assertEqual([{["app_foo", "greet"], "hello"}],
                    F("", [{"EMQX_FOO__GREET", "hello"}]))
    ].

translate_test_() ->
    F = fun (Str) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                     {Mapped, Conf} = map(demo_schema, M),
                     translate(demo_schema, Conf, Mapped) end,
    [ ?_assertEqual([{["app_foo", "range"], {1, 2}}],
                    F("foo.min=1, foo.max=2"))
    , ?_assertThrow({translation_error, _},
                    F("foo.min=2, foo.max=1"))
    ].

generate_compatibility_test() ->
    Conf = [
        {["foo", "setting"], "val"},
        {["foo", "min"], "1"},
        {["foo", "max"], "2"}
    ],

    Mappings = [
        cuttlefish_mapping:parse({mapping, "foo.setting", "app_foo.setting", [
            {datatype, string}
        ]}),
        cuttlefish_mapping:parse({mapping, "foo.min", "app_foo.range", [
            {datatype, integer}
        ]}),
        cuttlefish_mapping:parse({mapping, "foo.max", "app_foo.range", [
            {datatype, integer}
        ]})
    ],

    MinMax = fun(C) ->
        Min = cuttlefish:conf_get("foo.min", C),
        Max = cuttlefish:conf_get("foo.max", C),
        case Min < Max of
            true ->
                {Min, Max};
            _ ->
                throw("should be min < max")
        end end,

    Translations = [
        cuttlefish_translation:parse({translation, "app_foo.range", MinMax})
    ],

    {ok, Hocon} = hocon:binary("foo.setting=val,foo.min=1,foo.max=2",
                               #{format => richmap}),

    [{app_foo, C0}] = cuttlefish_generator:map({Translations, Mappings, []}, Conf),
    [{app_foo, C1}] = generate(demo_schema, Hocon),
    ?assertEqual(lists:ukeysort(1, C0), lists:ukeysort(1, C1)).

nest_test_() ->
    [ ?_assertEqual([{a, [{b, {1, 2}}]}],
                    nest([{["a", "b"], {1, 2}}]))
    , ?_assertEqual([{a, [{b, 1}, {c, 2}]}],
                    nest([{["a", "b"], 1}, {["a", "c"], 2}]))
    , ?_assertEqual([{a, [{b, 1}, {z, 2}]}, {x, [{a, 3}]}],
                    nest([{["a", "b"], 1}, {["a", "z"], 2}, {["x", "a"], 3}]))
    ].

with_envs(Fun, Args, [{_Name, _Value} | _] = Envs) ->
    set_envs(Envs),
    try
        Res = apply(Fun, Args),
        unset_envs(Envs),
        Res
    catch
        _:Reason ->
            unset_envs(Envs),
            {error, Reason}
    end.

set_envs([{_Name, _Value} | _] = Envs) ->
    lists:map(fun ({Name, Value}) -> os:putenv(Name, Value) end, Envs).

unset_envs([{_Name, _Value} | _] = Envs) ->
    lists:map(fun ({Name, _}) -> os:unsetenv(Name) end, Envs).

-endif.
