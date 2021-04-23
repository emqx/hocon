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
    Fields = apply(Schema, fields, []),
    do_map(Fields, RichMap, []).

do_map([], _RichMap, Acc) ->
    Acc;
do_map([{Field, SchemaFun} | More], RichMap, Acc) ->
    RichMap0 = apply_env(SchemaFun, Field, RichMap),
    Value = resolve_array(deep_get(Field, RichMap0, value)),
    Value0 = apply_converter(SchemaFun, Value),
    Validators = add_default_validator(SchemaFun(validator), SchemaFun(type)),
    Mapping = string:tokens(SchemaFun(mapping), "."),
    case {Value0, SchemaFun(default)} of
        {undefined, undefined} ->
            do_map(More, RichMap0, Acc);
        {undefined, Default} ->
            do_map(More, RichMap0, [{Mapping, Default} | Acc]);
        {Value0, _} ->
            % TODO when errorlist is returned, throw and print the field metadata
            Value1 = validate(Value0, Validators),
            do_map(More, RichMap0, [{Mapping, Value1} | Acc])
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
            Value;
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

deep_get_test() ->
    {ok, M0} = hocon:binary("a=1", #{format => richmap}),
    ?assertEqual(1, deep_get("a", M0, value)),
    ?assertMatch(#{line := 1}, deep_get("a", M0, metadata)),
    {ok, M1} = hocon:binary("a={b=1}", #{format => richmap}),
    ?assertEqual(1, deep_get("a.b", M1, value)),
    ?assertEqual(1, deep_get(["a", "b"], M1, value)),
    ?assertEqual(undefined, deep_get("a.c", M1, value)).

deep_put_test() ->
    {ok, M0} = hocon:binary("a=1", #{format => richmap}),
    NewM0 = deep_put("a", 2, M0, value),
    ?assertEqual(2, deep_get("a", NewM0, value)),

    {ok, M1} = hocon:binary("a={b=1}", #{format => richmap}),
    NewM1 = deep_put("a.b", 2, M1, value),
    ?assertEqual(2, deep_get("a.b", NewM1, value)),

    {ok, M2} = hocon:binary("a={b=1}", #{format => richmap}),
    NewM2 = deep_put("a.b", #{x => 1}, M2, value),
    ?assertEqual(#{x => 1}, deep_get("a.b", NewM2, value)).

richmap_to_map_test() ->
    {ok, M0} = hocon:binary("a.b = 1", #{format => richmap}),
    ?assertEqual(#{a => #{b => 1}}, richmap_to_map(M0)),

    {ok, M1} = hocon:binary("a.b = [1,2,3]", #{format => richmap}),
    ?assertEqual(#{a => #{b => [1, 2, 3]}}, richmap_to_map(M1)),

    {ok, M2} = hocon:binary("a.b = [1,2,{x=foo}]", #{format => richmap}),
    ?assertEqual(#{a => #{b => [1, 2, #{x => <<"foo">>}]}}, richmap_to_map(M2)).


mapping_test() ->
    {ok, M0} = hocon:binary("foo.setting=hello", #{format => richmap}),
    ?assertEqual([{["app_foo", "setting"], "hello"}], map(demo_schema, M0)),

    {ok, M1} = hocon:binary("foo.setting=1", #{format => richmap}),
    ?assertEqual(1, deep_get("foo.setting", M1, value)),
    % convert 1 to "1"
    ?assertEqual([{["app_foo", "setting"], "1"}], map(demo_schema, M1)),

    {ok, M2} = hocon:binary("foo.setting=[a,b,c]", #{format => richmap}),
    ?assertMatch([{["app_foo", "setting"], {errorlist, _}}],
                 map(demo_schema, M2)),

    {ok, M3} = hocon:binary("foo.endpoint=\"127.0.0.1\"", #{format => richmap}),
    ?assertEqual([{["app_foo", "endpoint"], {127, 0, 0, 1}}], map(demo_schema, M3)),

    {ok, M4} = hocon:binary("foo.setting=hi, foo.endpoint=hi", #{format => richmap}),
    ?assertMatch([{["app_foo", "endpoint"], {errorlist, _}},
                  {["app_foo", "setting"], "hi"}],
                 map(demo_schema, M4)),

    {ok, M5} = hocon:binary("foo.greet=foo", #{format => richmap}),
    ?assertMatch([{["app_foo", "greet"], {errorlist, [{error, _}]}}],
                 map(demo_schema, M5)),

    % array
    {ok, M6} = hocon:binary("foo.numbers=[1,2,3]", #{format => richmap}),
    ?assertEqual([{["app_foo", "numbers"], [1, 2, 3]}],
        map(demo_schema, M6)).

env_test() ->
    {ok, M0} = hocon:binary("foo.setting=hello", #{format => richmap}),
    Envs0 = [{"EMQX_FOO__SETTING", "hi"}, {"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}],
    ?assertEqual([{["app_foo", "setting"], "hi"}], with_envs(fun map/2, [demo_schema, M0], Envs0)),

    {ok, M1} = hocon:binary("foo.setting=hello", #{format => richmap}),
    Envs1 = [{"EMQX_MY_OVERRIDE", "yo"}, {"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}],
    ?assertEqual([{["app_foo", "setting"], "yo"}], with_envs(fun map/2, [demo_schema, M1], Envs1)),

    % array
    {ok, M2} = hocon:binary("foo.numbers=[1,2,3]", #{format => richmap}),
    Envs2 = [{"EMQX_FOO__NUMBERS", "[4,5,6]"}, {"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}],
    ?assertEqual([{["app_foo", "numbers"], [4, 5, 6]}],
                 with_envs(fun map/2, [demo_schema, M2], Envs2)).

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
