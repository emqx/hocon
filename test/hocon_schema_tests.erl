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
-module(hocon_schema_tests).

-include_lib("typerefl/include/types.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("hocon_private.hrl").

-behaviour(hocon_schema).

-export([structs/0, fields/1, validations/0]).

-define(VIRTUAL_ROOT, "").
-define(GEN_VALIDATION_ERR(Reason, Expr),
        ?_assertThrow({_, [{validation_error, Reason}]}, Expr)).
-define(VALIDATION_ERR(Reason, Expr),
        ?assertThrow({_, [{validation_error, Reason}]}, Expr)).

%% root names
structs() -> [bar].

fields(bar) ->
    [ {union_with_default, fun union_with_default/1}
    , {field1, fun field1/1}
    ];
fields(parent) ->
    [ {child, hoconsc:t(hoconsc:ref(child))}
    ];
fields(child) ->
    [ {name, string()}
    ];
fields(Other) ->
    demo_schema:fields(Other).

validations() -> [{check_child_name, fun check_child_name/1}].

check_child_name(Conf) ->
    %% nobody names their kid with single letters.
    case hocon_schema:get_value("parent", Conf) of
        undefined ->
            ok;
        P ->
            length(hocon_schema:get_value("child.name", P)) > 1
    end.

field1(type) -> string();
field1(_) -> undefined.

union_with_default(type) ->
    {union, [dummy, "priv.bool", "priv.int"]};
union_with_default(default) ->
    dummy;
union_with_default(_) -> undefined.

default_value_test() ->
    Conf = "{\"bar.field1\": \"foo\"}",
    Res = check(Conf),
    ?assertEqual(Res, check_plain(Conf)),
    ?assertEqual(#{<<"bar">> => #{ <<"union_with_default">> => dummy,
                                   <<"field1">> => "foo"}}, Res).

env_override_test() ->
    with_envs(
      fun() ->
              Conf = "{\"bar.field1\": \"foo\"}",
              Res = check(Conf),
              ?assertEqual(Res, check_plain(Conf, #{logger => fun(_, _) -> ok end})),
              ?assertEqual(#{<<"bar">> => #{ <<"union_with_default">> => #{<<"val">> => 111},
                                             <<"field1">> => ""}}, Res)
      end, [{"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"},
            {"EMQX_BAR__UNION_WITH_DEFAULT__VAL", "111"},
            {"EMQX_bar__field1", ""}
           ]).

unknown_env_test() ->
    Tester = self(),
    Ref = make_ref(),
    with_envs(
      fun() ->
              Conf = "{\"bar.field1\": \"foo\"}",
              Opts = #{logger => fun(Level, Msg) ->
                                         Tester ! {Ref, Level, Msg},
                                         ok
                                 end
                      },
              {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
              hocon_schema:check(?MODULE, RichMap, Opts)
      end, [{"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"},
            {"EMQX_BAR__UNION_WITH_DEFAULT__VAL", "111"},
            {"EMQX_bar__field1", ""},
            {"EMQX_BAR__UNKNOWNx", "x"}
           ]),
    receive
        {Ref, Level, Msg} ->
            ?assertEqual(warning, Level),
            ?assertEqual(<<"unknown_environment_variable_discarded: EMQX_BAR__UNKNOWNx">>, Msg)
    end.

check(Str) ->
    Opts = #{format => richmap},
    {ok, RichMap} = hocon:binary(Str, Opts),
    RichMap2 = hocon_schema:check(?MODULE, RichMap),
    hocon_schema:richmap_to_map(RichMap2).

check_plain(Str) ->
    check_plain(Str, #{}) .

check_plain(Str, Opts) ->
    {ok, Map} = hocon:binary(Str, #{}),
    hocon_schema:check_plain(?MODULE, Map, Opts).

mapping_test_() ->
    F = fun (Str) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                     {Mapped, _} = hocon_schema:map(demo_schema, M),
                     Mapped end,
    [ ?_assertEqual([{["app_foo", "setting"], "hello"}], F("foo.setting=hello"))
    , ?_assertEqual([{["app_foo", "setting"], "1"}], F("foo.setting=1"))
    , ?GEN_VALIDATION_ERR(_, F("foo.setting=[a,b,c]"))
    , ?_assertEqual([{["app_foo", "endpoint"], {127, 0, 0, 1}}], F("foo.endpoint=\"127.0.0.1\""))
    , ?GEN_VALIDATION_ERR(_, F("foo.setting=hi, foo.endpoint=hi"))
    , ?GEN_VALIDATION_ERR(_, F("foo.greet=foo"))
    , ?_assertEqual([{["app_foo", "numbers"], [1, 2, 3]}], F("foo.numbers=[1,2,3]"))
    , ?_assertEqual([{["a_b", "some_int"], 1}], F("a_b.some_int=1"))
    , ?_assertEqual([], F("foo.ref_x_y={some_int = 1}"))
    , ?GEN_VALIDATION_ERR(_, F("foo.ref_x_y={some_int = aaa}"))
    , ?_assertEqual([],
        F("foo.ref_x_y={some_dur = 5s}"))
    , ?_assertEqual([{["app_foo", "refjk"], #{<<"some_int">> => 1}}],
                    F("foo.ref_j_k={some_int = 1}"))
    , ?_assertThrow({_, [{validation_error, _},
                         {validation_error, _}]},
                    F("foo.greet=foo\n foo.endpoint=hi"))
    , ?_assertEqual([{["app_foo", "u"], #{<<"val">> => 1}}], F("b.u.val=1"))
    , ?_assertEqual([{["app_foo", "u"], #{<<"val">> => true}}], F("b.u.val=true"))
    , ?GEN_VALIDATION_ERR(#{reason := matched_no_union_member}, F("b.u.val=aaa"))
    , ?_assertEqual([{["app_foo", "u"], #{<<"val">> => 44}}], F("b.u.val=44"))
    , ?_assertEqual([{["app_foo", "arr"], [#{<<"val">> => 1}, #{<<"val">> => 2}]}],
                    F("b.arr=[{val=1},{val=2}]"))
    , ?GEN_VALIDATION_ERR(#{array_index := 3}, F("b.arr=[{val=1},{val=2},{val=a}]"))

    , ?GEN_VALIDATION_ERR(#{array_index := 2, reason := matched_no_union_member},
                          F("b.ua=[{val=1},{val=a},{val=true}]"))
    , ?_assertEqual([{["app_foo", "ua"], [#{<<"val">> => 1}, #{<<"val">> => true}]}],
                    F("b.ua=[{val=1},{val=true}]"))
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
    [{app_foo, C1}] = hocon_schema:generate(demo_schema, Hocon),
    {[{app_foo, C1}], Conf1} = hocon_schema:map_translate(demo_schema, Hocon, #{}),
    ?assertMatch(#{<<"foo">> := #{<<"max">> := 2, <<"min">> := 1, <<"setting">> := "val"}},
        hocon_schema:richmap_to_map(Conf1)),
    ?assertEqual(lists:ukeysort(1, C0), lists:ukeysort(1, C1)).

deep_get_test_() ->
    F = fun(Str, Key, Param) ->
                {ok, M} = hocon:binary(Str, #{format => richmap}),
                deep_get(Key, M, Param)
        end,
    [ ?_assertEqual(1, F("a=1", "a", ?HOCON_V))
    , ?_assertMatch(#{line := 1}, F("a=1", "a", ?METADATA))
    , ?_assertEqual(1, F("a={b=1}", "a.b", ?HOCON_V))
    , ?_assertEqual(undefined, F("a={b=1}", "a.c", ?HOCON_V))
    ].

deep_get(Path, Conf, Param) ->
    case hocon_schema:deep_get(Path, Conf) of
        undefined -> undefined;
        Map -> maps:get(Param, Map, undefined)
    end.

deep_put_test_() ->
    F = fun(Str, Key, Value) ->
                {ok, M} = hocon:binary(Str, #{format => richmap}),
                NewM = hocon_schema:deep_put(#{}, Key, Value, M),
                deep_get(Key, NewM, ?HOCON_V)
        end,
    [ ?_assertEqual(2, F("a=1", "a", 2))
    , ?_assertEqual(2, F("a={b=1}", "a.b", 2))
    , ?_assertEqual(#{x => 1}, F("a={b=1}", "a.b", #{x => 1}))
    ].

richmap_to_map_test_() ->
    F = fun(Str) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                    hocon_schema:richmap_to_map(M) end,
    [ ?_assertEqual(#{<<"a">> => #{<<"b">> => 1}}, F("a.b=1"))
    , ?_assertEqual(#{<<"a">> => #{<<"b">> => [1, 2, 3]}}, F("a.b = [1,2,3]"))
    , ?_assertEqual(#{<<"a">> =>
                      #{<<"b">> => [1, 2, #{<<"x">> => <<"foo">>}]}}, F("a.b = [1,2,{x=foo}]"))
    ].

env_test_() ->
    F = fun (Str, Envs) ->
                    {ok, M} = hocon:binary(Str, #{format => richmap}),
                    {Mapped, _} = with_envs(fun hocon_schema:map/2, [demo_schema, M],
                                            Envs ++ [{"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}]),
                    Mapped
        end,
    [ ?_assertEqual([{["app_foo", "setting"], "hi"}],
                    F("foo.setting=hello", [{"EMQX_FOO__SETTING", "hi"}]))
    , ?_assertEqual([{["app_foo", "setting"], "yo"}],
                    F("foo.setting=hello", [{"MY_OVERRIDE", "yo"}]))
    , ?_assertEqual([{["app_foo", "numbers"], [4, 5, 6]}],
                    F("foo.numbers=[1,2,3]", [{"EMQX_FOO__NUMBERS", "[4,5,6]"}]))
    , ?_assertEqual([{["app_foo", "greet"], "hello"}],
                    F("", [{"EMQX_FOO__GREET", "hello"}]))
    ].

env_object_val_test() ->
    Sc = #{structs => [root],
           fields => #{root => [{"val", hoconsc:t(hoconsc:ref(sub))}],
                       sub => [{"f1", integer()}]
                      }
          },
    Conf = "root = {val = {f1 = 43}}",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertEqual(#{<<"root">> => #{<<"val">> => #{<<"f1">> => 42}}},
        with_envs(fun hocon_schema:check_plain/2, [Sc, PlainMap],
            [ {"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}
            , {"EMQX_ROOT__VAL", "{f1:42}"}
            ])).

env_array_val_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{"val", hoconsc:array(string())}]
          },
    Conf = "val = [a,b]",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertEqual(#{<<"val">> => ["c", "d"]},
        with_envs(fun hocon_schema:check_plain/2, [Sc, PlainMap],
            [ {"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}
            , {"EMQX_VAL", "[c, d]"}
            ])).

env_ip_port_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{"val", string()}]
          },
    Conf = "val = \"127.0.0.1:1990\"",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertEqual(#{<<"val">> => "192.168.0.1:1991"},
        with_envs(fun hocon_schema:check_plain/2, [Sc, PlainMap],
            [ {"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}
            , {"EMQX_VAL", "192.168.0.1:1991"}
            ])).

translate_test_() ->
    F = fun (Str) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                     {Mapped, Conf} = hocon_schema:map(demo_schema, M),
                     hocon_schema:translate(demo_schema, Conf, Mapped) end,
    [ ?_assertEqual([{["app_foo", "range"], {1, 2}}],
                    F("foo.min=1, foo.max=2"))
    , ?_assertEqual([], F("foo.min=2, foo.max=1"))
    ].

nest_test_() ->
    [ ?_assertEqual([{a, [{b, {1, 2}}]}],
                    hocon_schema:nest([{["a", "b"], {1, 2}}]))
    , ?_assertEqual([{a, [{b, 1}, {c, 2}]}],
                    hocon_schema:nest([{["a", "b"], 1}, {["a", "c"], 2}]))
    , ?_assertEqual([{a, [{b, 1}, {z, 2}]}, {x, [{a, 3}]}],
                    hocon_schema:nest([{["a", "b"], 1}, {["a", "z"], 2}, {["x", "a"], 3}]))
    ].

with_envs(Fun, Envs) -> hocon_test_lib:with_envs(Fun, Envs).
with_envs(Fun, Args, Envs) -> hocon_test_lib:with_envs(Fun, Args, Envs).

union_as_enum_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{enum, hoconsc:union([a, b, c])}]
          },
    ?assertEqual(#{<<"enum">> => a},
                 hocon_schema:check_plain(Sc, #{<<"enum">> => a})),
    ?VALIDATION_ERR(#{reason := matched_no_union_member},
                    hocon_schema:check_plain(Sc, #{<<"enum">> => x})).

real_enum_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{val, hoconsc:enum([a, b, c])}]
          },
    ?assertEqual(#{<<"val">> => a},
                 hocon_schema:check_plain(Sc, #{<<"val">> => <<"a">>})),
    ?assertEqual(#{val => a},
                 hocon_schema:check_plain(Sc, #{<<"val">> => <<"a">>}, #{atom_key => true})),
    ?VALIDATION_ERR(#{reason := not_a_enum_symbol, value := x},
                    hocon_schema:check_plain(Sc, #{<<"val">> => <<"x">>})),
    ?VALIDATION_ERR(#{reason := unable_to_convert_to_enum_symbol,
                      value := {"badvalue"}},
                    hocon_schema:check_plain(Sc, #{<<"val">> => {"badvalue"}})).

array_of_enum_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{val, hoconsc:array(hoconsc:enum([a, b, c]))}]
          },
    Conf = "val = [a,b]",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertEqual(#{<<"val">> => [a, b]}, hocon_schema:check_plain(Sc, PlainMap)).

atom_key_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{val, binary()}]
          },
    Conf = "val = a",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(#{<<"val">> => <<"a">>},
                 hocon_schema:check_plain(Sc, PlainMap)),
    ?assertEqual(#{val => <<"a">>},
                 hocon_schema:check_plain(Sc, PlainMap, #{atom_key => true})),
    ?assertEqual(#{<<"val">> => <<"a">>},
                 hocon_schema:richmap_to_map(hocon_schema:check(Sc, RichMap))),
    ?assertEqual(#{val => <<"a">>},
                 hocon_schema:richmap_to_map(hocon_schema:check(Sc, RichMap, #{atom_key => true}))).

atom_key_array_test() ->
   Sc = #{structs => [?VIRTUAL_ROOT],
          fields => #{?VIRTUAL_ROOT => [{arr, hoconsc:array("sub")}],
                      "sub" => [{id, integer()}]
                     }
         },
    Conf = "arr = [{id = 1}, {id = 2}]",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertEqual(#{arr => [#{id => 1}, #{id => 2}]},
                 hocon_schema:check_plain(Sc, PlainMap, #{atom_key => true})),
    ?assertMatch({_, #{arr := [#{id := 1}, #{id := 2}]}},
                 hocon_schema:map(Sc, PlainMap, all, #{format => map, atom_key => true})).

%% if convert to non-existing atom
atom_key_failure_test() ->
   Sc = #{structs => [?VIRTUAL_ROOT],
           fields => #{?VIRTUAL_ROOT => [{<<"non_existing_atom_as_key">>, hoconsc:t(integer())}]
                      }
          },
    Conf = "non_existing_atom_as_key=1",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertError({non_existing_atom, <<"non_existing_atom_as_key">>},
                 hocon_schema:map(Sc, PlainMap, all, #{format => map, atom_key => true})).

return_plain_test_() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [ {metadata, hoconsc:t(string())}
                     , {type, hoconsc:t(string())}
                     , {value, hoconsc:t(string())}
                     ]},
    StrConf = "type=t, metadata=m, value=v",
    {ok, Conf} = hocon:binary(StrConf, #{format => richmap}),
    Opts = #{atom_key => true, return_plain => true},
    [ ?_assertMatch(#{metadata := "m", type := "t", value := "v"},
            hocon_schema:check(Sc, Conf, Opts))
    , ?_assertMatch({_, #{metadata := "m", type := "t", value := "v"}},
            hocon_schema:map(Sc, Conf, all, Opts))
    ].

validator_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{f1, hoconsc:t(integer(), #{validator => fun(X) -> X < 10 end})}]
          },
    ?assertEqual(#{<<"f1">> => 1}, hocon_schema:check_plain(Sc, #{<<"f1">> => 1})),
    ?VALIDATION_ERR(_, hocon_schema:check_plain(Sc, #{<<"f1">> => 11})),
    ok.

validator_crash_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{f1, hoconsc:t(integer(), #{validator => [fun(_) -> error(always) end]})}]
          },
    ?VALIDATION_ERR(#{reason := #{exception := {error, always}}},
                    hocon_schema:check_plain(Sc, #{<<"f1">> => 11})),
    ok.

nullable_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{f1, hoconsc:t(integer())},
                      {f2, hoconsc:t(string())},
                      {f3, hoconsc:t(integer(), #{default => 0})}
                     ]
          },
    ?assertEqual(#{<<"f2">> => "string", <<"f3">> => 0},
                 hocon_schema:check_plain(Sc, #{<<"f2">> => <<"string">>},
                                          #{nullable => true})),
    ?VALIDATION_ERR(#{reason := not_nullable, path := "f1"},
                    hocon_schema:check_plain(Sc, #{<<"f2">> => <<"string">>},
                                             #{nullable => false})),
    ok.

bad_root_test() ->
    Sc = #{structs => ["ab"],
           fields => #{"ab" => [{f1, hoconsc:t(integer(), #{default => 888})}]}
          },
    Input1 = "ab=1",
    {ok, Data1} = hocon:binary(Input1),
    ?VALIDATION_ERR(#{reason := bad_value_for_struct},
                    hocon_schema:check_plain(Sc, Data1)),
    ok.

bad_value_test() ->
    Conf = "person.id=123",
    {ok, M} = hocon:binary(Conf, #{format => richmap}),
    ?VALIDATION_ERR(#{reason := bad_value_for_struct},
                    begin
                        {Mapped, _} = hocon_schema:map(demo_schema, M),
                        Mapped
                    end).

multiple_structs_test() ->
    Sc = #{structs => [root],
           fields => #{root => [{f1, hoconsc:t(integer())},
                                {f2, hoconsc:t(string())}
                               ]}
          },
    Data = #{<<"root">> => #{<<"f2">> => <<"string">>, <<"f1">> => 1}},
    ?assertEqual(#{<<"root">> => #{<<"f2">> => "string", <<"f1">> => 1}},
                 hocon_schema:check_plain(Sc, Data, #{nullable => false})).

no_translation_test() ->
    ConfIn = "field1=w",
    {ok, M} = hocon:binary(ConfIn, #{format => richmap}),
    {Mapped, Conf} = hocon_schema:map(?MODULE, M),
    ?assertEqual(Mapped, hocon_schema:translate(?MODULE, Conf, Mapped)).

no_translation2_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{f1, integer()}]
          },
    ?assertEqual([], hocon_schema:translate(Sc, #{}, [])).

translation_crash_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{f1, hoconsc:t(integer())},
                      {f2, hoconsc:t(string())}
                     ],
           translations => #{"tr1" => [{"f3", fun(_Conf) -> error(always) end}]}
          },
    {ok, Data} = hocon:binary("f1=12,f2=foo", #{format => richmap}),
    {Mapped, Conf} = hocon_schema:map(?MODULE, Data),
    ?assertThrow({_, [{translation_error, #{reason := always, exception := error}}]},
                 hocon_schema:translate(Sc, Conf, Mapped)).

%% a schema module may have multiple root names (which the structs/0 returns)
%% map/2 checks maps all the roots
%% map/3 allows to pass in the names as the thrid arg.
%% this test is to cover map/3 API
map_just_one_root_test() ->
    Sc = #{structs => [root],
           fields => #{root => [{f1, hoconsc:t(integer())},
                                {f2, hoconsc:t(string())}
                               ]}
          },
    {ok, Data} = hocon:binary("root={f1=1,f2=bar}", #{format => richmap}),
    {[], NewData} = hocon_schema:map(Sc, Data, [root]),
    ?assertEqual(#{<<"root">> => #{<<"f2">> => "bar", <<"f1">> => 1}},
                 hocon_schema:richmap_to_map(NewData)).

validation_error_if_not_nullable_test() ->
  Sc = #{structs => [root],
           fields => #{root => [{f1, hoconsc:t(integer())},
                                {f2, hoconsc:t(string())}
                               ]}
        },
    Data = #{},
    ?VALIDATION_ERR(#{reason := not_nullable},
                    hocon_schema:check_plain(Sc, Data, #{nullable => false})).

unknown_fields_test_() ->
    Conf = "person.id.num=123,person.name=mike",
    {ok, M} = hocon:binary(Conf, #{format => richmap}),
    ?GEN_VALIDATION_ERR(#{reason := unknown_fields,
                          unknown := [{<<"name">>, #{line := 1}}]
                         }, hocon_schema:map(demo_schema, M, all)).

nullable_field_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{f1, hoconsc:t(integer(), #{nullable => false})}]
          },
    ?VALIDATION_ERR(#{reason := not_nullable, path := "f1"},
                    hocon_schema:check_plain(Sc, #{})),
    ok.

bad_input_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{f1, integer()}]
          },
    %% NOTE: this is not a valid richmap, intended to test a crash
    BadInput = #{?HOCON_V => #{<<"f1">> => 1}},
    ?assertError({bad_richmap, 1}, hocon_schema:map(Sc, BadInput)).

not_array_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{f1, hoconsc:array(integer())}]
          },
    BadInput = #{<<"f1">> => 1},
    ?VALIDATION_ERR(#{reason := not_array},
                    hocon_schema:check_plain(Sc, BadInput)).

converter_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [{f1, hoconsc:t(integer(),
                                     #{converter => fun(<<"one">>) -> 1 end})}]
          },
    Input = #{<<"f1">> => <<"one">>},
    BadIn = #{<<"f1">> => <<"two">>},
    ?assertEqual(#{<<"f1">> => 1}, hocon_schema:check_plain(Sc, Input)),
    ?VALIDATION_ERR(#{reason := converter_crashed},
                    hocon_schema:check_plain(Sc, BadIn)).

no_dot_in_root_name_test() ->
    Sc = #{structs => ["a.b"],
           fields => [{f1, hoconsc:t(integer())}]
          },
    ?assertError({bad_root_name, _, "a.b"},
                hocon_schema:check(Sc, #{<<"a">> => 1})).

union_of_structs_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => #{?VIRTUAL_ROOT => [{f1, hoconsc:union([dummy, "m1", "m2"])}],
                       "m1" => [{m1, integer()}],
                       "m2" => [{m2, integer()}]
                      }
          },
    ?assertEqual(#{f1 => #{m1 => 1}}, check_return_atom_keys(Sc, "f1.m1=1")),
    ?assertEqual(#{f1 => #{m2 => 2}}, check_return_atom_keys(Sc, "f1.m2=2")),
    ?assertEqual(#{f1 => dummy}, check_return_atom_keys(Sc, "f1=dummy")),
    ?VALIDATION_ERR(#{reason := matched_no_union_member},
                    check_return_atom_keys(Sc, "f1=other")),
    ?VALIDATION_ERR(#{reason := matched_no_union_member},
                    check_return_atom_keys(Sc, "f1.m3=3")),
    ok.

multiple_errors_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => #{?VIRTUAL_ROOT => [{m1, integer()}, {m2, integer()}]}
          },
    ?assertThrow({_, [{validation_error, #{path := "m1"}},
                      {validation_error, #{path := "m2"}}]},
                 check_return_atom_keys(Sc, "m1=a,m2=b")),
    ok.

check_return_atom_keys(Sc, Input) ->
    {ok, Map} = hocon:binary(Input),
    hocon_schema:check_plain(Sc, Map, #{atom_key => true}).

find_struct_test() ->
    ?assertEqual(foo, hocon_schema:find_struct(demo_schema, "foo")),
    ?assertThrow({unknown_struct_name, _, "noexist"},
                 hocon_schema:find_struct(demo_schema, "noexist")).


sensitive_data_obfuscation_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => #{?VIRTUAL_ROOT =>
                       [{secret, hoconsc:t(string(),
                                           #{sensitive => true,
                                             override_env => "OBFUSCATION_TEST"
                                            })}]}
          },
    Self = self(),
    with_envs(
      fun() ->
              hocon_schema:check_plain(Sc, #{<<"secret">> => "aaa"},
                                       #{logger => fun(_Level, Msg) -> Self ! Msg end}),
              receive
                  #{hocon_env_var_name := "OBFUSCATION_TEST", path := Path, value := Value} ->
                      ?assertEqual("secret", Path),
                      ?assertEqual("*******", Value)
              end
      end, [{"OBFUSCATION_TEST", "bbb"}]),
    ok.

remote_ref_test() ->
    Sc = #{structs => [root],
           fields => #{root => [{f1, hoconsc:t(hoconsc:ref(?MODULE, bar))}
                               ]}
          },
    {ok, Data} = hocon:binary("root={f1={field1=foo}}", #{}),
    ?assertMatch(#{root := #{f1 := #{field1 := "foo"}}},
                 hocon_schema:check_plain(Sc, Data, #{atom_key => true})),
    ok.

local_ref_test() ->
    Input = "parent={child={name=marribay}}",
    {ok, Data} = hocon:binary(Input, #{}),
    ?assertMatch(#{parent := #{child := #{name := "marribay"}}},
                 hocon_schema:check_plain(?MODULE, Data, #{atom_key => true}, [parent])),
    ok.

integrity_check_test() ->
    Sc = #{structs => [root],
           fields => #{root => [{f1, integer()},
                                {f2, integer()}
                               ]},
           validations => [{"f1 > f2",
                            fun(C) ->
                                    F1 = hocon_schema:get_value("root.f1", C),
                                    F2 = hocon_schema:get_value("root.f2", C),
                                    F1 > F2
                            end
                           }]
          },
    Data1 = "root={f1=1,f2=2}",
    ?VALIDATION_ERR(#{reason := integrity_validation_failure,
                      validation_name := "f1 > f2"
                     },
                    check_plain_bin(Sc, Data1, #{atom_key => true})),
    Data2 = "root={f1=3,f2=2}",
    ?assertEqual(#{root => #{f1 => 3, f2 => 2}},
                   check_plain_bin(Sc, Data2, #{atom_key => true})),
    ok.

integrity_crash_test() ->
    Sc = #{structs => [root],
           fields => #{root => [{f1, integer()}]},
           validations => [{"always-crash", fun(_) -> error(always) end}]
          },
    Data1 = "root={f1=1}",
    ?VALIDATION_ERR(#{reason := integrity_validation_crash,
                      validation_name := "always-crash"
                     },
                    check_plain_bin(Sc, Data1, #{atom_key => true})),
    ok.

check_plain_bin(Sc, Data, Opts) ->
    {ok, Conf} = hocon:binary(Data, #{}),
    hocon_schema:check_plain(Sc, Conf, Opts).

default_value_for_array_field_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => [ {k, hoconsc:t(hoconsc:array(string()), #{default => [<<"a">>, <<"b">>]})}
                     , {x, string()}
                     ]
          },
    Conf = "x = y",
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(#{<<"k">> => ["a", "b"], <<"x">> => "y"}, hocon_schema:richmap_to_map(
       hocon_schema:check(Sc, RichMap))).

default_value_map_field_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => #{?VIRTUAL_ROOT => [ {k, #{type => hoconsc:ref(sub),
                                                default => #{<<"a">> => <<"foo">>,
                                                             <<"b">> => <<"bar">>}}}
                                        , {x, string()}
                                        ],
                       sub => [{a, string()}, {b, string()}]
                      }
          },
    Conf = "x = y",
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(#{<<"k">> => #{<<"a">> => "foo",
                                <<"b">> => "bar"},
                   <<"x">> => "y"},
                 hocon_schema:richmap_to_map(hocon_schema:check(Sc, RichMap))).

default_value_for_null_enclosing_struct_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => #{?VIRTUAL_ROOT => [ {"l1", #{type => hoconsc:ref("l2")}} ],
                       "l2" => [{"l2", #{type => integer(), default => 22}},
                                {"l3", #{type => integer()}}
                               ]
                      }},
    Conf = "",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(#{<<"l1">> => #{<<"l2">> => 22}},
                 hocon_schema:check_plain(Sc, PlainMap, #{nullable => true})),
    ?assertEqual(#{<<"l1">> => #{<<"l2">> => 22}},
                 hocon_schema:check(Sc, RichMap, #{nullable => true, return_plain => true})).

fill_defaults_test() ->
    Sc = #{structs => ["a"],
           fields => #{"a" =>
               [ {b, hoconsc:t(integer(), #{default => 888})}
               , {c, hoconsc:t(integer(), #{
                   default => "15s",
                   converter => fun (Dur) -> hocon_postprocess:duration(Dur) end})}
               ]}
          },
    ?assertMatch(#{<<"a">> := #{<<"b">> := 888, <<"c">> := 15000}},
        hocon_schema:check_plain(Sc, #{}, #{nullable => true})),
    ?assertMatch(#{<<"a">> := #{<<"b">> := 888, <<"c">> := "15s"}},
        hocon_schema:check_plain(Sc, #{}, #{nullable => true, no_conversion => true})),
    ok.

root_array_test_() ->
    Sc = #{structs => [{array, foo}],
           fields => #{foo => [ {"kling", hoconsc:t(integer())},
                                {"klang", hoconsc:t(integer())}
                              ]
                      }
          },
    Conf = "foo = [{kling = 1, klang=2},
                   {kling = 2, klang=4},
                   {kling = 3, klang=6}]",
    [{"richmap",
      fun() ->
              {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
              ?assertEqual(#{<<"foo">> => [#{<<"kling">> => 1, <<"klang">> => 2},
                                           #{<<"kling">> => 2, <<"klang">> => 4},
                                           #{<<"kling">> => 3, <<"klang">> => 6}]},
                           hocon_schema:richmap_to_map(hocon_schema:check(Sc, RichMap)))
      end},
     {"plainmap",
      fun() ->
              {ok, PlainMap} = hocon:binary(Conf, #{}),
              ?assertEqual(#{<<"foo">> => [#{<<"kling">> => 1, <<"klang">> => 2},
                                           #{<<"kling">> => 2, <<"klang">> => 4},
                                           #{<<"kling">> => 3, <<"klang">> => 6}]},
                           hocon_schema:check(Sc, PlainMap, #{format => map}))
      end},
     {"empty",
      fun() ->
              {ok, Map} = hocon:binary("foo = []", #{format => richmap}),
              ?assertEqual(#{<<"foo">> => []},
                           hocon_schema:richmap_to_map(
                                hocon_schema:check(Sc, Map, #{format => richmap})))
      end}
    ].

root_array_env_override_test() ->
    Sc = #{structs => [{array, foo}],
           fields => #{foo => [ {"kling", hoconsc:t(integer())},
                                {"klang", hoconsc:t(integer())}
                              ]
                      }
          },
    with_envs(
      fun() ->
              Conf = "",
              {ok, PlainMap} = hocon:binary(Conf, #{}),
              Opts = #{format => map, nullable => true},
              ?assertEqual(#{<<"foo">> => [#{<<"kling">> => 111},
                                           #{<<"klang">> => 222}
                                          ]},
                           hocon_schema:check(Sc, PlainMap, Opts))
      end, [{"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"},
            {"EMQX_FOO__1__KLING", "111"},
            {"EMQX_FOO__2__KLANG", "222"}
           ]).

ref_nullable_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => #{?VIRTUAL_ROOT => [ {k, #{type => hoconsc:ref(sub),
                                                nullable => {true, recursively}}}
                                        , {x, string()}
                                        ],
                       sub => [{a, string()}, {b, string()}]
                      }
          },
    Conf = "x = y",
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(#{<<"x">> => "y"},
                 hocon_schema:richmap_to_map(hocon_schema:check(Sc, RichMap))).

lazy_test() ->
    Sc = #{structs => [?VIRTUAL_ROOT],
           fields => #{?VIRTUAL_ROOT => [ {k, #{type => hoconsc:lazy(integer())}}
                                        , {x, string()}
                                        ]
                      }
          },
    Conf = "x = y, k=whatever",
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(#{<<"x">> => "y", <<"k">> => <<"whatever">>},
                 hocon_schema:richmap_to_map(hocon_schema:check(Sc, RichMap))).
