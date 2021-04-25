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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([map/2]).

map(Schema, RichMap) ->
    Namespaces = apply(Schema, namespaces, []),
    lists:append([do_map(apply(Schema, fields, [N]), N, RichMap, []) || N <- Namespaces]).

do_map([], _Namespace, _RichMap, Acc) ->
    Acc;
do_map([{Field, SchemaFun} | More], Namespace, RichMap, Acc) ->
    Field0 = Namespace ++ "." ++ Field,
    RichMap0 = apply_env(SchemaFun, Field0, RichMap),
    Value = resolve_array(deep_get(Field0, RichMap0, value)),
    Value0 = apply_converter(SchemaFun, Value),
    Validators = add_default_validator(SchemaFun(validator), SchemaFun(type)),
    Mapping = string:tokens(SchemaFun(mapping), "."),
    case {Value0, SchemaFun(default)} of
        {undefined, undefined} ->
            do_map(More, Namespace, RichMap0, Acc);
        {undefined, Default} ->
            do_map(More, Namespace, RichMap0, [{Mapping, Default} | Acc]);
        {Value0, _} ->
            % TODO when errorlist is returned, throw and print the field metadata
            Value1 = validate(Value0, Validators),
            do_map(More, Namespace, RichMap0, [{Mapping, Value1} | Acc])
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
add_default_validator(Validators, Type) ->
    TypeChecker = fun (Value) -> typerefl:typecheck(Type, Value) end,
    [TypeChecker | Validators].

validate(Value, Validators) ->
    validate(Value, Validators, []).
validate(Value, [], []) ->
    Value;
validate(_Value, [], Errors) ->
    {errorlist, Errors};
validate(Value, [H | T], Errors) ->
    case H(Value) of
        ok ->
            validate(Value, T, Errors);
        {error, Reason} ->
            validate(Value, T, [{error, Reason} | Errors])
    end.

deep_get([], RichMap, Param) ->
    maps:get(Param, RichMap);
deep_get([H | T], RichMap, Param) when is_list(H) ->
    case maps:get(list_to_atom(H), maps:get(value, RichMap, undefined), undefined) of
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
    #{list_to_atom(H) => #{Param => Value}};
nested_richmap([H | T], Value, Param) ->
    #{list_to_atom(H) => #{value => nested_richmap(T, Value, Param)}}.

resolve_array(ArrayOfRichMap) when is_list(ArrayOfRichMap) ->
    [richmap_to_map(R) || R <- ArrayOfRichMap];
resolve_array(Other) ->
    Other.

richmap_to_map(RichMap) when is_map(RichMap) ->
    richmap_to_map(maps:iterator(RichMap), #{}).
richmap_to_map(Iter, Map) ->
    case maps:next(Iter) of
        {metadata, _, I} ->
            richmap_to_map(I, Map);
        {type, _, I} ->
            richmap_to_map(I, Map);
        {value, M, I} when is_map(M) ->
            richmap_to_map(maps:iterator(M), #{});
        {value, A, I} when is_list(A) ->
            resolve_array(A);
        {value, V, I} ->
            V;
        {K, V, I} ->
            richmap_to_map(I, Map#{K => richmap_to_map(V)});
        none ->
            Map
    end.

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
    [ ?_assertEqual(#{a => #{b => 1}}, F("a.b=1"))
    , ?_assertEqual(#{a => #{b => [1, 2, 3]}}, F("a.b = [1,2,3]"))
    , ?_assertEqual(#{a => #{b => [1, 2, #{x => <<"foo">>}]}}, F("a.b = [1,2,{x=foo}]"))
    ].


mapping_test_() ->
    F = fun (Str) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                     map(demo_schema, M) end,
    [ ?_assertEqual([{["app_foo", "setting"], "hello"}], F("foo.setting=hello"))
    , ?_assertEqual([{["app_foo", "setting"], "1"}], F("foo.setting=1"))
    , ?_assertMatch([{["app_foo", "setting"], {errorlist, _}}], F("foo.setting=[a,b,c]"))
    , ?_assertEqual([{["app_foo", "endpoint"], {127, 0, 0, 1}}], F("foo.endpoint=\"127.0.0.1\""))
    , ?_assertMatch([{["app_foo", "endpoint"], {errorlist, _}},
                    {["app_foo", "setting"], "hi"}],
                   F("foo.setting=hi, foo.endpoint=hi"))
    , ?_assertMatch([{["app_foo", "greet"], {errorlist, [{error, _}]}}], F("foo.greet=foo"))
    , ?_assertEqual([{["app_foo", "numbers"], [1, 2, 3]}], F("foo.numbers=[1,2,3]"))
    , ?_assertEqual([{["a", "b", "some_int"], 1}], F("a.b.some_int=1"))
    ].

env_test_() ->
    F = fun (Str, Envs) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                           with_envs(fun map/2, [demo_schema, M],
                                     Envs ++ [{"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}]) end,
    [ ?_assertEqual([{["app_foo", "setting"], "hi"}],
                    F("foo.setting=hello", [{"EMQX_FOO__SETTING", "hi"}]))
    , ?_assertEqual([{["app_foo", "setting"], "yo"}],
                    F("foo.setting=hello", [{"EMQX_MY_OVERRIDE", "yo"}]))
    , ?_assertEqual([{["app_foo", "numbers"], [4, 5, 6]}],
                    F("foo.numbers=[1,2,3]", [{"EMQX_FOO__NUMBERS", "[4,5,6]"}]))
    , ?_assertEqual([{["app_foo", "greet"], "hello"}],
                    F("", [{"EMQX_FOO__GREET", "hello"}]))
    , ?_assertEqual([{["a", "b", "birthdays"], [#{m => 1, d => 1}, #{m => 12, d => 12}]}],
                    F("", [{"EMQX_A__B__BIRTHDAYS", "[{m=1, d=1}, {m=12, d=12}]"}]))
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
