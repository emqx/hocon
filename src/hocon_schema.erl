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
    Value = deep_get(Field, RichMap, value),
    Value0 = apply_converter(SchemaFun, Value),
    Validators = add_default_validator(SchemaFun(validator), SchemaFun(type)),
    Mapping = string:tokens(SchemaFun(mapping), "."),
    case {Value0, SchemaFun(default)} of
        {undefined, undefined} ->
            do_map(More, RichMap, Acc);
        {undefined, Default} ->
            do_map(More, RichMap, [{Mapping, Default} | Acc]);
        {Value0, _} ->
            % TODO when errorlist is returned, throw and print the field metadata
            Value1 = validate(Value0, Validators),
            do_map(More, RichMap, [{Mapping, Value1} | Acc])
    end.

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

% TODO: support richmap inside array. e.g. a=[{x=1}]
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

-ifdef(TEST).

deep_get_test() ->
    {ok, M0} = hocon:binary("a=1", #{format => richmap}),
    ?assertEqual(1, deep_get("a", M0, value)),
    ?assertMatch(#{line := 1}, deep_get("a", M0, metadata)),
    {ok, M1} = hocon:binary("a={b=1}", #{format => richmap}),
    ?assertEqual(1, deep_get("a.b", M1, value)),
    ?assertEqual(1, deep_get(["a", "b"], M1, value)),
    ?assertEqual(undefined, deep_get("a.c", M1, value)).

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

    % additional validators
    {ok, M5} = hocon:binary("foo.greet=foo", #{format => richmap}),
    ?assertEqual([{["app_foo", "greet"], {errorlist, [{error, greet}]}}],
                 map(demo_schema, M5)).


-endif.
