-module(hocon_schema_tests).

-include_lib("typerefl/include/types.hrl").
-include_lib("eunit/include/eunit.hrl").

-behaviour(hocon_schema).

-export([structs/0, fields/1]).

%% namespaces
structs() -> [bar].

fields(bar) ->
    [ {union_with_default, fun union_with_default/1}
    , {field1, fun field1/1}
    ];
fields(Other) -> demo_schema:fields(Other).

field1(type) -> string();
field1(_) -> undefined.

union_with_default(type) ->
    {union, [dummy, "priv.bool", "priv.int"]};
union_with_default(default) ->
    dummy;
union_with_default(_) -> undefined.

default_value_test() ->
    Res = check("{\"bar.field1\": \"foo\"}"),
    ?assertEqual(#{<<"bar">> => #{ <<"union_with_default">> => dummy,
                                   <<"field1">> => "foo"}}, Res).

env_overide_test() ->
    hocon_schema:with_envs(
      fun() ->
              Res = check("{\"bar.field1\": \"foo\"}"),
              ?assertEqual(#{<<"bar">> => #{ <<"union_with_default">> => #{<<"val">> => 111},
                                             <<"field1">> => "foo"}}, Res)
      end, [{"EMQX_BAR__UNION_WITH_DEFAULT_VALUE_VAL", "111"}]).

check(Str) ->
    Opts = #{format => richmap},
    {ok, RichMap} = hocon:binary(Str, Opts),
    RichMap2 = hocon_schema:check(?MODULE, RichMap),
    hocon_schema:richmap_to_map(RichMap2).
