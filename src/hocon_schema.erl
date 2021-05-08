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
-export([deep_get/3]).

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
translations(Mod) when is_atom(Mod) -> Mod:translations();
translations(#{translations := Trs}) -> Trs.

-spec translation(schema(), name()) -> [translation()].
translation(Mod, Name) when is_atom(Mod) -> Mod:translation(Name);
translation(#{translation := Tr}, Name) -> Tr(Name).

generate(Schema, RichMap) ->
    {Mapped, RichMap0} = map(Schema, RichMap),
    Translated = translate(Schema, RichMap0, Mapped),
    nest(Translated).

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

%% TODO: spec
translate(Schema, Conf, Mapped) ->
    Namespaces = translations(Schema),
    Res = lists:append([do_translate(translation(Schema, N), str(N), Conf, Mapped) ||
                        N <- Namespaces]),
    ok = find_error(Res),
    Res.

do_translate([], _Namespace, _Conf, Acc) ->
    Acc;
do_translate([{MappedField, Translator} | More], Namespace, Conf, Acc) ->
    MappedField0 = Namespace ++ "." ++ MappedField,
    try
        do_translate(More, Namespace, Conf,
                     [{string:tokens(MappedField0, "."), Translator(Conf)} | Acc])
    catch
        _:Reason ->
            Error = {string:tokens(MappedField0, "."),
                     {error, {translation_error, Reason, MappedField0}}},
            do_translate(More, Namespace, Conf, [Error | Acc])
    end.

map(Schema, RichMap) ->
    Namespaces = structs(Schema),
    F = fun (Namespace, {Acc, Conf}) ->
        {Mapped, NewConf} = do_map(fields(Schema, Namespace), str(Namespace), Conf, []),
        {lists:append(Acc, Mapped), NewConf} end,
    {Mapped, RichMap0} = lists:foldl(F, {[], RichMap}, Namespaces),
    ok = find_error(Mapped),
    {Mapped, RichMap0}.

str(A) when is_atom(A) -> atom_to_list(A);
str(S) -> S.

do_map([], _Namespace, RichMap, Acc) ->
    {Acc, RichMap};
do_map([{Field, SchemaFun} | More], Namespace, RichMap, Acc) ->
    Field0 = Namespace ++ "." ++ str(Field),
    RichMap0 = apply_env(SchemaFun, Field0, RichMap),
    Value = resolve_array(deep_get(Field0, RichMap0, value)),
    Value0 = case SchemaFun(type) of
                 {ref, _} -> Value;
                 _ -> apply_converter(SchemaFun, Value) end,
    Validators = add_default_validator(SchemaFun(validator), SchemaFun(type)),
    NewAcc = fun (undefined, {error, _} = E, A) -> [{ref, E} | A];
                 (undefined, _, A) -> A;
                 (Mapping, V, A) -> [{string:tokens(Mapping, "."), V} | A] end,
    case {Value0, SchemaFun(default)} of
        {undefined, undefined} ->
            do_map(More, Namespace, RichMap0, Acc);
        {undefined, Default} ->
            do_map(More, Namespace, RichMap0, NewAcc(SchemaFun(mapping), Default, Acc));
        {Value0, _} ->
            Value1 = case validate(Value0, Validators) of
                         {errorlist, Reasons} ->
                             AllInfo = deep_get(Field0, RichMap0, all),
                             {error, {validation_error, Reasons, Field0, AllInfo}};
                         V ->
                             richmap_to_map(V)
                     end,
            do_map(More, Namespace, RichMap0, NewAcc(SchemaFun(mapping), Value1, Acc))
    end.

apply_env(SchemaFun, Field, RichMap) ->
    Prefix = os:getenv("HOCON_ENV_OVERRIDE_PREFIX", ""),
    Key = Prefix ++ string:join(string:replace(string:uppercase(Field), ".", "__", all), ""),
    OverrideKey = case SchemaFun(override_env) of
                      undefined ->
                          "";
                      Sth ->
                          Prefix ++ Sth
                  end,
    case {os:getenv(Key), os:getenv(OverrideKey)} of
        {false, false} ->
            RichMap;
        {V0, false} ->
            deep_put(Field, string_to_hocon(V0), RichMap, value);
        {_, V1} ->
            deep_put(Field, string_to_hocon(V1), RichMap, value)
    end.

string_to_hocon(Str) when is_list(Str) ->
    {ok, RichMap} = hocon:binary("key = " ++ Str, #{format => richmap}),
    deep_get("key", RichMap, value).

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

add_default_validator(undefined, Type) ->
    add_default_validator([], Type);
add_default_validator(Validator, Type) when is_function(Validator) ->
    add_default_validator([Validator], Type);
add_default_validator(Validators, {ref, Fields}) ->
    RefChecker = fun (V) -> try
                                {M, _} = do_map(Fields, "", #{value => V}, []),
                                find_error(M),
                                ok
                            catch
                                _:{validation_error, Errors} -> {error, Errors}
                            end
                 end,
    [RefChecker | Validators];
add_default_validator(Validators, Type) ->
    TypeChecker = fun (Value) -> typerefl:typecheck(Type, Value) end,
    [TypeChecker | Validators].

validate(Value, Validators) ->
    validate(Value, Validators, []).
validate(Value, [], []) ->
    Value;
validate(_Value, [], Reasons) ->
    {errorlist, Reasons};
validate(Value, [H | T], Reasons) ->
    case H(Value) of
        ok ->
            validate(Value, T, Reasons);
        {error, Reason} ->
            validate(Value, T, [Reason | Reasons])
    end.

deep_get([], RichMap, all) ->
    RichMap;
deep_get([], RichMap, Param) ->
    maps:get(Param, RichMap);
deep_get([H | T], RichMap, Param) when is_list(H) ->
    case maps:get(list_to_binary(H), maps:get(value, RichMap, undefined), undefined) of
        undefined ->
            undefined;
        ChildRichMap ->
            deep_get(T, ChildRichMap, Param)
    end;
deep_get(Str, RichMap, Param) when is_list(Str) ->
    deep_get(string:tokens(Str, "."), RichMap, Param).

deep_put([H | _T] = L, Value, RichMap, Param) when is_list(H) ->
    hocon_util:do_deep_merge(RichMap, #{value => nested_richmap(L, Value, Param)});
deep_put(Str, Value, RichMap, Param) when is_list(Str) ->
    deep_put(string:tokens(Str, "."), Value, RichMap, Param).

nested_richmap([H], Value, Param) ->
    #{list_to_binary(H) => #{Param => Value}};
nested_richmap([H | T], Value, Param) ->
    #{list_to_binary(H) => #{value => nested_richmap(T, Value, Param)}}.

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
        [{translation_error, _, _} | _] = Errors ->
            translation_error(Errors);
        [] ->
            ok
    end.
do_find_error([], Res) ->
    Res;
do_find_error([{_MappedField, {error, E}} | More], Errors) ->
    do_find_error(More, [E | Errors]);
do_find_error([_ | More], Errors) ->
    do_find_error(More, Errors).

validation_error(Errors) ->
    F = fun ({validation_error, Reasons, Field, M}, Acc) ->
        case hocon:filename_of(M) of
            undefined ->
                Acc ++ io_lib:format("validation_failed: ~p = ~p at_line ~p,~n~s~n",
                       [Field,
                        richmap_to_map(hocon:value_of(M)),
                        hocon:line_of(M),
                        lists:append(Reasons)]);
            F ->
                Acc ++ io_lib:format("validation_failed: ~p = ~p " ++
                                     "in_file ~p at_line ~p,~n~s~n",
                       [Field,
                        richmap_to_map(hocon:value_of(M)),
                        F,
                        hocon:line_of(M),
                        lists:append(Reasons)])
        end
    end,
    ErrorInfo = lists:foldl(F, "", Errors),
    throw({validation_error, iolist_to_binary(ErrorInfo)}).

translation_error(Errors) ->
    F = fun ({translation_error, Reason, MappedField}, Acc) ->
                Acc ++ io_lib:format("translation_failed: ~p,~n~s~n",
                    [MappedField, Reason])
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
    [ ?_assertEqual([{["app_foo", "setting"], "hello"}], F("foo.setting=hello"))
    , ?_assertEqual([{["app_foo", "setting"], "1"}], F("foo.setting=1"))
    , ?_assertThrow({validation_error,
        <<"validation_failed: \"foo.setting\" = [<<\"a\">>,<<\"b\">>,<<\"c\">>] at_line 1,\n"
          "Expected type: string() when\n"
          "  string() :: [char()].\n"
          "Got: [<<\"a\">>,<<\"b\">>,<<\"c\">>]\n\n">>}, F("foo.setting=[a,b,c]"))
    , ?_assertEqual([{["app_foo", "endpoint"], {127, 0, 0, 1}}], F("foo.endpoint=\"127.0.0.1\""))
    , ?_assertThrow({validation_error,
        <<"validation_failed: \"foo.endpoint\" = <<\"hi\">> at_line 1,\n"
          "Expected type: ip4_address()() when\n"
          "  ip4_address()() :: {0..255, 0..255, 0..255, 0..255}.\n"
          "Got: \"hi\"\n\n">>}, F("foo.setting=hi, foo.endpoint=hi"))
    , ?_assertThrow({validation_error,
        <<"validation_failed: \"foo.greet\" = <<\"foo\">> at_line 1,\n"
          "Expected type: string(\"^hello$\")\nGot: \"foo\"\n\n">>},
        F("foo.greet=foo"))
    , ?_assertEqual([{["app_foo", "numbers"], [1, 2, 3]}], F("foo.numbers=[1,2,3]"))
    , ?_assertEqual([{["a", "b", "some_int"], 1}], F("a.b.some_int=1"))
    , ?_assertEqual([], F("foo.ref_x_y={some_int = 1}"))
    , ?_assertThrow({validation_error,
        <<"validation_failed: \"foo.ref_x_y\" = #{<<\"some_int\">> => <<\"aaa\">>} at_line 1,\n"
          "validation_failed: \".some_int\" = <<\"aaa\">> at_line 1,\n"
          "Expected type: integer()\n"
          "Got: aaa\n\n\n">>},
        F("foo.ref_x_y={some_int = aaa}"))
    , ?_assertEqual([{["app_foo", "refjk"], #{<<"some_int">> => 1}}],
                    F("foo.ref_j_k={some_int = 1}"))
    , ?_assertThrow({validation_error,
        <<"validation_failed: \"foo.endpoint\" = <<\"hi\">> at_line 2,\n"
          "Expected type: ip4_address()() when\n"
          "  ip4_address()() :: {0..255, 0..255, 0..255, 0..255}.\n"
          "Got: \"hi\"\n\n"
          "validation_failed: \"foo.greet\" = <<\"foo\">> at_line 1,\n"
          "Expected type: string(\"^hello$\")\n"
          "Got: \"foo\"\n\n">>},
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
    , ?_assertEqual([{["a", "b", "birthdays"], [#{<<"d">> => 1, <<"m">> => 1},
                                                #{<<"d">> => 12, <<"m">> => 12}]}],
                    F("", [{"EMQX_A__B__BIRTHDAYS", "[{m=1, d=1}, {m=12, d=12}]"}]))
    ].

translate_test_() ->
    F = fun (Str) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                     {Mapped, Conf} = map(demo_schema, M),
                     translate(demo_schema, Conf, Mapped) end,
    [ ?_assertEqual([{["app_foo", "range"], {1, 2}}],
                    F("foo.min=1, foo.max=2"))
    , ?_assertThrow({translation_error,
                    <<"translation_failed: \"app_foo.range\",\n"
                      "should be min < max\n">>},
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
