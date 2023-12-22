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
-module(hocon_tconf_tests).

-include_lib("typerefl/include/types.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("hocon_private.hrl").
-include("hoconsc.hrl").

-export([roots/0, fields/1, validations/0, desc/1]).

-define(GEN_VALIDATION_ERR(Reason, Expr),
    ?_assertThrow({_, [Reason]}, Expr)
).
-define(VALIDATION_ERR(Reason, Expr),
    ?assertThrow({_, [Reason]}, Expr)
).

roots() -> [bar].

fields(bar) ->
    [
        {union_with_default, fun union_with_default/1},
        {field1, fun field1/1},
        {optional_secret, fun optional_secret/1},
        {host, fun host/1}
    ];
fields(parent) ->
    [{child, hoconsc:mk(hoconsc:ref(child))}];
fields(child) ->
    [{name, string()}];
fields(Other) ->
    demo_schema:fields(Other).

desc(bar) ->
    "This is bar";
desc(parent) ->
    "This is parent";
desc(child) ->
    "This is child";
desc(_) ->
    "This is something else".

validations() -> [{check_child_name, fun check_child_name/1}].

check_child_name(Conf) ->
    %% nobody names their kid with single letters.
    case hocon_maps:get("parent", Conf) of
        undefined ->
            ok;
        P ->
            length(hocon_maps:get("child.name", P)) > 1
    end.

field1(type) -> string();
field1(desc) -> "field1 desc";
field1(sensitive) -> true;
field1(_) -> undefined.

optional_secret(type) -> string();
optional_secret(desc) -> "optional secret";
optional_secret(sensitive) -> true;
optional_secret(required) -> false;
optional_secret(_) -> undefined.

host(type) -> string();
host(required) -> false;
host(desc) -> "host desc";
host(_) -> undefined.

union_with_default(type) ->
    ?UNION([dummy, "priv.bool", "priv.int"]);
union_with_default(default) ->
    dummy;
union_with_default(_) ->
    undefined.

default_value_test() ->
    Conf = "{bar.field1: \"foo\"}",
    Res = check(Conf, #{format => richmap}),
    ?assertEqual(Res, check_plain(Conf)),
    ?assertEqual(
        #{
            <<"bar">> => #{
                <<"union_with_default">> => dummy,
                <<"field1">> => "foo"
            }
        },
        Res
    ),
    %% check foo and dummy is binary.
    ?assertEqual(
        #{
            <<"bar">> =>
                #{
                    <<"field1">> => <<"foo">>,
                    <<"union_with_default">> => <<"dummy">>
                }
        },
        hocon_tconf:make_serializable(?MODULE, Res, #{})
    ).

obfuscate_sensitive_values_test() ->
    Conf = "{bar.field1: \"foo\"}",
    Res = check(Conf, #{format => richmap}),
    Res1 = check_plain(Conf, #{obfuscate_sensitive_values => true}),
    ?assertNotEqual(Res, Res1),
    ?assertEqual(
        #{
            <<"bar">> => #{
                <<"union_with_default">> => dummy,
                <<"field1">> => <<"******">>
            }
        },
        Res1
    ).

obfuscate_sensitive_map_test() ->
    {ok, Hocon} = hocon:binary(
        "foo.setting=val,foo.min=1,foo.max=2",
        #{format => richmap}
    ),
    Opts1 = #{obfuscate_sensitive_values => true},
    Conf1 = map_translate_conf(Hocon, Opts1),
    ?assertMatch(
        #{<<"foo">> := #{<<"max">> := 2, <<"min">> := 1, <<"setting">> := <<"******">>}},
        richmap_to_map(Conf1)
    ),
    ok.

map_translate_conf(Hocon, Opts1) ->
    [{app_foo, C1}] = hocon_tconf:generate(demo_schema, Hocon, Opts1),
    {[{app_foo, C1}], Conf1} = hocon_tconf:map_translate(demo_schema, Hocon, Opts1),
    Conf1.

obfuscate_sensitive_fill_default_test() ->
    {ok, Hocon} = hocon:binary(
        "foo.min=1,foo.max=2",
        #{format => richmap}
    ),
    Opts1 = #{obfuscate_sensitive_values => true, make_serializable => true},
    Conf1 = map_translate_conf(Hocon, Opts1),
    ?assertMatch(
        #{<<"foo">> := #{<<"max">> := 2, <<"min">> := 1, <<"setting">> := <<"******">>}},
        richmap_to_map(Conf1)
    ),

    Opts2 = #{make_serializable => true},
    Conf2 = map_translate_conf(Hocon, Opts2),
    ?assertMatch(
        #{<<"foo">> := #{<<"max">> := 2, <<"min">> := 1, <<"setting">> := <<"default">>}},
        richmap_to_map(Conf2)
    ),

    Opts3 = #{obfuscate_sensitive_values => true},
    Conf3 = map_translate_conf(Hocon, Opts3),
    ?assertMatch(
        #{<<"foo">> := #{<<"max">> := 2, <<"min">> := 1, <<"setting">> := <<"******">>}},
        richmap_to_map(Conf3)
    ),
    ok.

nest_ref_fill_default_test() ->
    Module = nest_ref_fill_default_demo,
    Str = "broker {perf {} route_batch_clean = false }",
    {ok, HoconRichMap} = hocon:binary(Str, #{format => richmap}),
    OptsRichMap = #{make_serializable => true, format => richmap},
    [] = hocon_tconf:generate(Module, HoconRichMap, OptsRichMap),
    {[], ConfRichMap} = hocon_tconf:map_translate(Module, HoconRichMap, OptsRichMap),
    Expect = #{
        <<"broker">> =>
            #{
                <<"perf">> =>
                    #{
                        <<"route_lock_type">> => <<"key">>,
                        <<"trie_compaction">> => true
                    },
                <<"route_batch_clean">> => false
            }
    },
    ?assertEqual(Expect, richmap_to_map(ConfRichMap)),

    {ok, HoconMap} = hocon:binary(Str, #{format => map}),
    OptsMap = #{make_serializable => true, format => map},
    [] = hocon_tconf:generate(Module, HoconMap, OptsMap),
    {[], ConfMap} = hocon_tconf:map_translate(Module, HoconMap, OptsMap),
    ?assertEqual(Expect, ConfMap).

env_override_test() ->
    with_envs(
        fun() ->
            Conf = "{bar.field1: \"foo\", bar.host: \"127.0.0.1\"}",
            Opts = #{format => richmap},
            Res = check(Conf, Opts#{apply_override_envs => true}),
            ?assertEqual(
                Res,
                check_plain(Conf, #{
                    logger => fun(_, _) -> ok end,
                    apply_override_envs => true
                })
            ),
            ?assertEqual(
                #{
                    <<"bar">> => #{
                        <<"union_with_default">> => #{<<"val">> => 111},
                        <<"field1">> => "",
                        <<"host">> => "127.0.0.2"
                    }
                },
                Res
            ),

            {ok, Conf1} = hocon:binary(Conf, Opts),
            Conf2 = hocon_tconf:merge_env_overrides(?MODULE, Conf1, all, Opts),
            %% check env raw binary field1 and host is binary.
            ?assertMatch(
                #{
                    <<"bar">> := #{
                        <<"union_with_default">> := #{<<"val">> := 111},
                        <<"field1">> := <<"">>,
                        <<"host">> := <<"127.0.0.2">>
                    }
                },
                richmap_to_map(Conf2)
            ),
            Conf3 = hocon_tconf:check(?MODULE, Conf2, Opts#{apply_override_envs => false}),
            Conf4 = richmap_to_map(Conf3),
            ?assertEqual(Res, Conf4)
        end,
        envs([
            {"EMQX_BAR__UNION_WITH_DEFAULT__VAL", "111"},
            {"EMQX_bar__field1", ""},
            {"EMQX_bar__host", "127.0.0.2"}
        ])
    ).

%% by default apply_override_envs is false
no_env_override_test() ->
    with_envs(
        fun() ->
            Conf = "{bar.field1: \"foo\"}",
            Res = check(Conf, #{format => richmap}),
            PlainRes = check_plain(Conf, #{logger => fun(_, _) -> ok end}),
            ?assertEqual(Res, PlainRes),
            ?assertEqual(
                #{
                    <<"bar">> => #{
                        <<"union_with_default">> => dummy,
                        <<"field1">> => "foo"
                    }
                },
                Res
            )
        end,
        envs([
            {"EMQX_BAR__UNION_WITH_DEFAULT__VAL", "211"},
            %% the envs are not expected to be applied
            {"EMQX_bar__field1", ""}
        ])
    ).

unknown_env_test() ->
    Tester = self(),
    Ref = make_ref(),
    with_envs(
        fun() ->
            Conf = "{bar.field1: \"foo\"}",
            Opts = #{
                logger => fun(Level, Msg) ->
                    Tester ! {Ref, Level, Msg},
                    ok
                end
            },
            {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
            hocon_tconf:check(?MODULE, RichMap, Opts#{apply_override_envs => true})
        end,
        envs([
            {"EMQX_BAR__UNION_WITH_DEFAULT__VAL", "111"},
            {"EMQX_bar__field1", ""},
            {"EMQX_BAR__UNKNOWNx", "x"},
            {"EMQX_UNKNOWNx", "x"},
            {"EMQX___", "x"}
        ])
    ),
    Unknown = iolist_to_binary(io_lib:format("~p", [["EMQX_BAR__UNKNOWNx"]])),
    receive
        {Ref, Level, Msg} ->
            ?assertEqual(warning, Level),
            ?assertEqual(<<"unknown_env_vars: ", Unknown/binary>>, Msg)
    end.

check(Str, Opts) ->
    {ok, RichMap} = hocon:binary(Str, Opts),
    RichMap2 = hocon_tconf:check(?MODULE, RichMap, Opts),
    richmap_to_map(RichMap2).

check_plain(Str) ->
    check_plain(Str, #{}).

check_plain(Str, Opts) ->
    {ok, Map} = hocon:binary(Str, #{}),
    hocon_tconf:check_plain(?MODULE, Map, Opts).

mapping_test_() ->
    F = fun(Str) ->
        {ok, M} = hocon:binary(Str, #{format => richmap}),
        {Mapped, _} = hocon_tconf:map(demo_schema, M),
        Mapped
    end,
    Setting = {["app_foo", "setting"], "default"},
    [
        ?_assertEqual([{["app_foo", "setting"], "hello"}], F("foo.setting=hello")),
        ?_assertEqual([{["app_foo", "setting"], "1"}], F("foo.setting=1")),
        ?GEN_VALIDATION_ERR(_, F("foo.setting=[a,b,c]")),
        ?_assertEqual(
            [
                {["app_foo", "endpoint"], {127, 0, 0, 1}},
                Setting
            ],
            F("foo.endpoint=\"127.0.0.1\"")
        ),
        ?GEN_VALIDATION_ERR(_, F("foo.setting=hi, foo.endpoint=hi")),
        ?GEN_VALIDATION_ERR(_, F("foo.greet=foo")),
        ?_assertEqual(
            [{["app_foo", "numbers"], [1, 2, 3]}, Setting],
            F("foo.numbers=[1,2,3]")
        ),
        ?_assertEqual([{["a_b", "some_int"], 1}, Setting], F("a_b.some_int=1")),
        ?_assertEqual([Setting], F("foo.ref_x_y={some_int = 1}")),
        ?GEN_VALIDATION_ERR(_, F("foo.ref_x_y={some_int = aaa}")),
        ?_assertEqual(
            [Setting],
            F("foo.ref_x_y={some_dur = 5s}")
        ),
        ?_assertEqual(
            [{["app_foo", "refjk"], #{<<"some_int">> => 1}}, Setting],
            F("foo.ref_j_k={some_int = 1}")
        ),
        ?_assertThrow(
            {_, [
                #{kind := validation_error},
                #{kind := validation_error}
            ]},
            F("foo.greet=foo\n foo.endpoint=hi")
        ),
        ?_assertEqual([{["app_foo", "u"], #{<<"val">> => 1}}, Setting], F("b.u.val=1")),
        ?_assertEqual([{["app_foo", "u"], #{<<"val">> => true}}, Setting], F("b.u.val=true")),
        ?GEN_VALIDATION_ERR(#{reason := matched_no_union_member}, F("b.u.val=aaa")),
        ?_assertEqual([{["app_foo", "u"], #{<<"val">> => 44}}, Setting], F("b.u.val=44")),
        ?_assertEqual(
            [{["app_foo", "arr"], [#{<<"val">> => 1}, #{<<"val">> => 2}]}, Setting],
            F("b.arr=[{val=1},{val=2}]")
        ),
        ?GEN_VALIDATION_ERR(#{path := "b.arr.3.val"}, F("b.arr=[{val=1},{val=2},{val=a}]")),

        ?GEN_VALIDATION_ERR(
            #{path := "b.ua.2", reason := matched_no_union_member},
            F("b.ua=[{val=1},{val=a},{val=true}]")
        ),
        ?_assertEqual(
            [{["app_foo", "ua"], [#{<<"val">> => 1}, #{<<"val">> => true}]}, Setting],
            F("b.ua=[{val=1},{val=true}]")
        )
    ].

map_key_test() ->
    Sc = #{roots => [{"val", hoconsc:map(key, string())}]},
    GoodConf = "val = {good_GOOD = value}",
    {ok, GoodMap} = hocon:binary(GoodConf, #{format => map}),
    ?assertEqual(
        #{<<"val">> => #{<<"good_GOOD">> => "value"}},
        hocon_tconf:check_plain(Sc, GoodMap, #{apply_override_envs => false})
    ),

    BadConfs = ["val = {\"_bad\" = value}", "val = {\"bad_-n\" = value}"],
    lists:foreach(
        fun(BadConf) ->
            {ok, BadMap} = hocon:binary(BadConf, #{format => map}),
            ?GEN_VALIDATION_ERR(
                #{path := "val", reason := invalid_map_key},
                hocon_tconf:check_plain(Sc, BadMap, #{apply_override_envs => false})
            )
        end,
        BadConfs
    ),
    ok.

generate_compatibility_test() ->
    Conf = [
        {["foo", "setting"], "val"},
        {["foo", "min"], "1"},
        {["foo", "max"], "2"}
    ],

    Mappings = [
        cuttlefish_mapping:parse(
            {mapping, "foo.setting", "app_foo.setting", [
                {datatype, string}
            ]}
        ),
        cuttlefish_mapping:parse(
            {mapping, "foo.min", "app_foo.range", [
                {datatype, integer}
            ]}
        ),
        cuttlefish_mapping:parse(
            {mapping, "foo.max", "app_foo.range", [
                {datatype, integer}
            ]}
        )
    ],

    MinMax = fun(C) ->
        Min = cuttlefish:conf_get("foo.min", C),
        Max = cuttlefish:conf_get("foo.max", C),
        case Min < Max of
            true ->
                {Min, Max};
            _ ->
                throw("should be min < max")
        end
    end,

    Translations = [
        cuttlefish_translation:parse({translation, "app_foo.range", MinMax})
    ],

    {ok, Hocon} = hocon:binary(
        "foo.setting=val,foo.min=1,foo.max=2",
        #{format => richmap}
    ),

    [{app_foo, C0}] = cuttlefish_generator:map({Translations, Mappings, []}, Conf),
    [{app_foo, C1}] = hocon_tconf:generate(demo_schema, Hocon),
    {[{app_foo, C1}], Conf1} = hocon_tconf:map_translate(demo_schema, Hocon, #{}),
    ?assertMatch(
        #{<<"foo">> := #{<<"max">> := 2, <<"min">> := 1, <<"setting">> := "val"}},
        richmap_to_map(Conf1)
    ),
    ?assertEqual(lists:ukeysort(1, C0), lists:ukeysort(1, C1)).

env_test_() ->
    F = fun(Str, Envs) ->
        {ok, M} = hocon:binary(Str, #{format => richmap}),
        Opts = #{apply_override_envs => true},
        {Mapped, _} = with_envs(
            fun hocon_tconf:map/4,
            [demo_schema, M, all, Opts],
            envs(Envs)
        ),
        Mapped
    end,
    Setting = {["app_foo", "setting"], "default"},
    [
        ?_assertEqual(
            [{["app_foo", "setting"], "hi"}],
            F("foo.setting=hello", [{"EMQX_FOO__SETTING", "hi"}])
        ),
        ?_assertEqual(
            [{["app_foo", "numbers"], [4, 5, 6]}, Setting],
            F("foo.numbers=[1,2,3]", [{"EMQX_FOO__NUMBERS", "[4,5,6]"}])
        ),
        ?_assertEqual(
            [{["app_foo", "greet"], "hello"}, Setting],
            F("", [{"EMQX_FOO__GREET", "hello"}])
        )
    ].

env_object_val_test() ->
    Sc = #{
        roots => [root],
        fields => #{
            root => [{"val", hoconsc:mk(hoconsc:ref(sub))}],
            sub => [{"f1", integer()}]
        }
    },
    Conf = "root = {val = {f1 = 43}}",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertEqual(
        #{<<"root">> => #{<<"val">> => #{<<"f1">> => 42}}},
        with_envs(
            fun hocon_tconf:check_plain/3,
            [Sc, PlainMap, #{apply_override_envs => true}],
            envs([{"EMQX_ROOT__VAL", "{f1:42}"}])
        )
    ).

env_array_val_test() ->
    Sc = #{roots => [{"val", hoconsc:array(string())}]},
    Conf = "val = [a,b]",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertEqual(
        #{<<"val">> => ["c", "d"]},
        with_envs(
            fun hocon_tconf:check_plain/3,
            [Sc, PlainMap, #{apply_override_envs => true}],
            envs([{"EMQX_VAL", "[c, d]"}, {"EMQX___", "discard"}])
        )
    ).

env_array_element_override_test_() ->
    Sc = #{roots => [{"val", hoconsc:array(string())}]},
    Conf = "val = [a,b]",
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    {ok, Map} = hocon:binary(Conf, #{format => map}),
    RC = fun() -> hocon_tconf:check(Sc, RichMap, #{apply_override_envs => true}) end,
    PC = fun() -> hocon_tconf:check_plain(Sc, Map, #{apply_override_envs => true}) end,
    F = fun(Check) ->
        with_envs(
            fun() ->
                hocon_maps:ensure_plain(Check())
            end,
            [],
            envs([
                {"EMQX_VAL", "[c, d]"},
                {"EMQX_VAL__1", "x"},
                {"EMQX_VAL__2", "y"}
            ])
        )
    end,
    [
        ?_assertEqual(#{<<"val">> => ["x", "y"]}, F(RC)),
        ?_assertEqual(#{<<"val">> => ["x", "y"]}, F(PC))
    ].

env_map_val_test() ->
    Sc = #{roots => [{"val", hoconsc:map(key, string())}]},
    Conf = "val = {key = value}",
    {ok, Map} = hocon:binary(Conf, #{format => map}),
    ?assertEqual(
        #{<<"val">> => #{<<"key">> => "value2"}},
        with_envs(
            fun hocon_tconf:check_plain/3,
            [Sc, Map, #{apply_override_envs => true}],
            envs([{"EMQX_VAL__KEY", "value2"}])
        )
    ).

env_ip_port_test() ->
    Sc = #{roots => [{"val", string()}]},
    Conf = "val = \"127.0.0.1:1990\"",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertEqual(
        #{<<"val">> => "192.168.0.1:1991"},
        with_envs(
            fun hocon_tconf:check_plain/3,
            [Sc, PlainMap, #{apply_override_envs => true}],
            envs([{"EMQX_VAL", "192.168.0.1:1991"}])
        )
    ).

translate_test_() ->
    F = fun(Str) ->
        {ok, M} = hocon:binary(Str, #{format => richmap}),
        {Mapped, Conf} = hocon_tconf:map(demo_schema, M),
        hocon_tconf:translate(demo_schema, Conf, Mapped)
    end,
    Setting = {["app_foo", "setting"], "default"},
    [
        ?_assertEqual(
            [{["app_foo", "range"], {1, 2}}, Setting],
            F("foo.min=1, foo.max=2")
        ),
        ?_assertEqual([Setting], F("foo.min=2, foo.max=1"))
    ].

nest_test_() ->
    [
        ?_assertEqual(
            [{a, [{b, {1, 2}}]}],
            hocon_tconf:nest([{["a", "b"], {1, 2}}])
        ),
        ?_assertEqual(
            [{a, [{b, 1}, {c, 2}]}],
            hocon_tconf:nest([{["a", "b"], 1}, {["a", "c"], 2}])
        ),
        ?_assertEqual(
            [{a, [{b, 1}, {z, 2}]}, {x, [{a, 3}]}],
            hocon_tconf:nest([{["a", "b"], 1}, {["a", "z"], 2}, {["x", "a"], 3}])
        )
    ].

with_envs(Fun, Envs) -> hocon_test_lib:with_envs(Fun, Envs).
with_envs(Fun, Args, Envs) -> hocon_test_lib:with_envs(Fun, Args, Envs).

union_as_enum_test() ->
    Sc = #{roots => [{enum, hoconsc:union([a, b, c], <<"string()">>)}]},
    ?assertEqual(
        #{<<"enum">> => a},
        hocon_tconf:check_plain(Sc, #{<<"enum">> => a})
    ),
    ?VALIDATION_ERR(
        #{reason := matched_no_union_member},
        hocon_tconf:check_plain(Sc, #{<<"enum">> => x})
    ).

real_enum_test() ->
    Sc = #{roots => [{val, hoconsc:enum([a, b, c, 1])}]},
    ?assertEqual(
        #{<<"val">> => a},
        hocon_tconf:check_plain(Sc, #{<<"val">> => <<"a">>})
    ),
    ?assertEqual(
        #{<<"val">> => 1},
        hocon_tconf:check_plain(Sc, #{<<"val">> => <<"1">>})
    ),
    ?VALIDATION_ERR(
        #{reason := not_a_enum_symbol, value := bin},
        hocon_tconf:check_plain(Sc, #{<<"val">> => <<"bin">>})
    ),
    ?assertEqual(
        #{val => a},
        hocon_tconf:check_plain(Sc, #{<<"val">> => <<"a">>}, #{atom_key => true})
    ),
    ?VALIDATION_ERR(
        #{reason := not_a_enum_symbol, value := x},
        hocon_tconf:check_plain(Sc, #{<<"val">> => <<"x">>})
    ),
    ?VALIDATION_ERR(
        #{
            reason := unable_to_convert_to_enum_symbol,
            value := {"badvalue"}
        },
        hocon_tconf:check_plain(Sc, #{<<"val">> => {"badvalue"}})
    ).

bad_enum_test() ->
    ?assertError({bad_enum_type, "a"}, hoconsc:mk(hoconsc:enum(["a"]))),
    ?assertError({bad_enum_type, <<"a">>}, hoconsc:mk(hoconsc:enum([<<"a">>]))),
    ok.

bad_array_index_test() ->
    Sc = #{roots => [{val, hoconsc:array(integer())}]},
    Conf = "val = {first = 1}",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertThrow(
        {_, [
            #{
                kind := validation_error,
                bad_array_index_keys := [<<"first">>],
                path := "val"
            }
        ]},
        hocon_tconf:check_plain(Sc, PlainMap)
    ).

array_of_enum_test() ->
    Sc = #{roots => [{val, hoconsc:array(hoconsc:enum([a, b, c]))}]},
    Conf = "val = [a,b]",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertEqual(#{<<"val">> => [a, b]}, hocon_tconf:check_plain(Sc, PlainMap)).

atom_key_test() ->
    Sc = #{roots => [{val, binary()}]},
    Conf = "val = a",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(
        #{<<"val">> => <<"a">>},
        hocon_tconf:check_plain(Sc, PlainMap)
    ),
    ?assertEqual(
        #{val => <<"a">>},
        hocon_tconf:check_plain(Sc, PlainMap, #{atom_key => true})
    ),
    ?assertEqual(
        #{<<"val">> => <<"a">>},
        richmap_to_map(hocon_tconf:check(Sc, RichMap))
    ),
    ?assertEqual(
        #{val => <<"a">>},
        richmap_to_map(hocon_tconf:check(Sc, RichMap, #{atom_key => true}))
    ).

invalid_utf8_binary_test() ->
    Sc = #{roots => [{val, binary()}]},
    %% The HTTP API may take invalid UTF-8 characters as input.
    PlainMap = #{<<"val">> => <<"您好-测试">>},
    ?assertThrow(
        {_, [
            #{
                kind := validation_error,
                path := "val",
                reason := #{expected := "binary()"},
                value := {error, _, _}
            }
        ]},
        hocon_tconf:check_plain(Sc, PlainMap)
    ).

atom_key_array_test() ->
    Sc = #{
        roots => [{arr, hoconsc:array("sub")}],
        fields => #{"sub" => [{id, integer()}]}
    },
    Conf = "arr = [{id = 1}, {id = 2}]",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertEqual(
        #{arr => [#{id => 1}, #{id => 2}]},
        hocon_tconf:check_plain(Sc, PlainMap, #{atom_key => true})
    ),
    ?assertMatch(
        {_, #{arr := [#{id := 1}, #{id := 2}]}},
        hocon_tconf:map(Sc, PlainMap, all, #{format => map, atom_key => true})
    ).

%% if convert to non-existing atom
atom_key_failure_test() ->
    Sc = #{roots => [{<<"non_existing_atom_as_key">>, hoconsc:mk(integer())}]},
    Conf = "non_existing_atom_as_key=1",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    ?assertError(
        {non_existing_atom, <<"non_existing_atom_as_key">>},
        hocon_tconf:map(Sc, PlainMap, all, #{format => map, atom_key => true})
    ).

return_plain_test_() ->
    Sc = #{
        roots => [
            {metadata, hoconsc:mk(string())},
            {type, hoconsc:mk(string())},
            {value, hoconsc:mk(string())}
        ]
    },
    StrConf = "type=t, metadata=m, value=v",
    {ok, Conf} = hocon:binary(StrConf, #{format => richmap}),
    Opts = #{atom_key => true, return_plain => true},
    [
        ?_assertMatch(
            #{metadata := "m", type := "t", value := "v"},
            hocon_tconf:check(Sc, Conf, Opts)
        ),
        ?_assertMatch(
            {_, #{metadata := "m", type := "t", value := "v"}},
            hocon_tconf:map(Sc, Conf, all, Opts)
        )
    ].

validator_test() ->
    Sc = #{roots => [{f1, hoconsc:mk(integer(), #{validator => fun(X) -> X < 10 end})}]},
    ?assertEqual(#{<<"f1">> => 1}, hocon_tconf:check_plain(Sc, #{<<"f1">> => 1})),
    ?VALIDATION_ERR(_, hocon_tconf:check_plain(Sc, #{<<"f1">> => 11})),
    ok.

validator_error_test() ->
    Sc = #{roots => [{f1, hoconsc:mk(string(), #{validator => fun not_empty/1})}]},
    ?assertEqual(#{<<"f1">> => "1"}, hocon_tconf:check_plain(Sc, #{<<"f1">> => "1"})),
    Expect = #{kind => validation_error, path => "f1", reason => "Can not be empty", value => ""},
    ?VALIDATION_ERR(Expect, hocon_tconf:check_plain(Sc, #{<<"f1">> => ""})),
    ok.

not_empty("") -> {error, "Can not be empty"};
not_empty(_) -> ok.

validator_crash_test() ->
    Sc = #{roots => [{f1, hoconsc:mk(integer(), #{validator => [fun(_) -> error(always) end]})}]},
    ?VALIDATION_ERR(
        #{reason := #{exception := {error, always}, stacktrace := _}},
        hocon_tconf:check_plain(Sc, #{<<"f1">> => 11})
    ),
    ok.

validator_throw_test() ->
    Sc = #{roots => [{f1, hoconsc:mk(integer(), #{validator => [fun(_) -> throw(foo) end]})}]},
    ?VALIDATION_ERR(
        #{reason := foo},
        hocon_tconf:check_plain(Sc, #{<<"f1">> => 11})
    ),
    ok.

required_test() ->
    Sc = #{
        roots => [
            {f1, hoconsc:mk(integer())},
            {f2, hoconsc:mk(string())},
            {f3, hoconsc:mk(integer(), #{default => 0})}
        ]
    },
    ?assertEqual(
        #{<<"f2">> => "string", <<"f3">> => 0},
        hocon_tconf:check_plain(
            Sc,
            #{<<"f2">> => <<"string">>},
            #{required => false}
        )
    ),
    ?VALIDATION_ERR(
        #{reason := required_field, path := "f1"},
        hocon_tconf:check_plain(
            Sc,
            #{<<"f2">> => <<"string">>},
            #{required => true}
        )
    ),

    ScRequired = #{
        roots => [
            {f1, hoconsc:mk(integer(), #{required => false})},
            {f2, hoconsc:mk(string(), #{required => true})},
            {f3, hoconsc:mk(integer(), #{default => 0})}
        ]
    },
    ?VALIDATION_ERR(
        #{reason := required_field, path := "f2"},
        hocon_tconf:check_plain(ScRequired, #{}, #{required => false})
    ),

    ?VALIDATION_ERR(
        #{reason := required_field, path := "f2"},
        hocon_tconf:check_plain(ScRequired, #{}, #{})
    ),

    ?assertEqual(
        #{<<"f2">> => "string", <<"f3">> => 0},
        hocon_tconf:check_plain(ScRequired, #{<<"f2">> => <<"string">>}, #{required => true})
    ),
    ok.

required_array_test() ->
    Sc = #{
        roots => [
            {f1, hoconsc:array(hoconsc:union([hoconsc:ref("s1")]))}
        ],
        fields => #{
            "s1" => [
                {id, hoconsc:mk(integer(), #{required => true})},
                {name, string()}
            ]
        }
    },
    ?VALIDATION_ERR(
        #{reason := required_field, path := "f1.1.id"},
        hocon_tconf:check_plain(Sc, #{<<"f1">> => [#{<<"name">> => "foo"}]}, #{})
    ),
    ok.

%% for union of unions the type path is an important piece of information in the error context
type_stack_test() ->
    Sc = #{
        roots => [
            {f1, hoconsc:array(hoconsc:union([hoconsc:ref("s1")]))}
        ],
        fields => #{
            "s1" => [{maybe_v, hoconsc:union([hoconsc:ref("s2")])}],
            "s2" => [
                {id, hoconsc:mk(integer(), #{required => true})},
                {name, string()}
            ]
        }
    },
    Value = #{<<"f1">> => [#{<<"maybe_v">> => #{<<"name">> => "foo"}}]},
    ?VALIDATION_ERR(
        #{reason := required_field, path := "f1.1.maybe_v.id", matched_type := "s1/s2"},
        hocon_tconf:check_plain(Sc, Value, #{})
    ),
    ok.

%% for union of unions, when sub-union check failed
type_stack_cannot_concatenate_test() ->
    Sc = #{
        roots => [
            {f1, hoconsc:array(hoconsc:union([hoconsc:ref("s1")]))}
        ],
        fields => #{
            "s1" => [{maybe_v, hoconsc:union([hoconsc:ref("s2")])}],
            "s2" => [
                {id, hoconsc:mk(integer(), #{required => true})},
                {name, hoconsc:mk(string(), #{required => true})}
            ]
        }
    },
    ?VALIDATION_ERR(
        #{
            path := "f1.1.maybe_v",
            matched_type := "s1/s2",
            errors := [_ | _]
        },
        hocon_tconf:check_plain(Sc, #{<<"f1">> => [#{<<"maybe_v">> => #{}}]}, #{})
    ),
    ok.

recursive_deprecation_test() ->
    Sc = #{
        roots => [
            {f1, hoconsc:mk(integer())},
            {f2, hoconsc:mk(hoconsc:ref(sub), #{deprecated => {since, "0.1.2"}, required => true})}
        ],
        fields => #{sub => [{a, string()}, {b, string()}]}
    },
    ?assertEqual(
        #{<<"f1">> => 1},
        hocon_tconf:check_plain(
            Sc,
            #{<<"f1">> => 1},
            #{required => true}
        )
    ).

deprecation_test() ->
    Sc = #{
        roots => [
            {f1, hoconsc:mk(integer())},
            {f2, hoconsc:mk(string())},
            {f3, hoconsc:mk(integer(), #{deprecated => {since, "0.1.1"}})}
        ]
    },
    ?assertEqual(
        #{<<"f2">> => "string"},
        hocon_tconf:check_plain(
            Sc,
            #{<<"f2">> => <<"string">>},
            #{required => false}
        )
    ),
    ?assertEqual(
        #{<<"f1">> => 1, <<"f2">> => "string"},
        hocon_tconf:check_plain(
            Sc,
            #{<<"f1">> => 1, <<"f2">> => <<"string">>},
            #{required => true}
        )
    ),
    ?assertEqual(
        #{<<"f2">> => "string"},
        hocon_tconf:check_plain(
            Sc,
            #{<<"f2">> => <<"string">>, <<"f3">> => "whatever"},
            #{required => false}
        )
    ).

deprecation_sub_field_test() ->
    Sc = #{
        roots => [
            {f1, hoconsc:mk(integer())},
            {f2, hoconsc:ref("dep")}
        ],
        fields => #{"dep" => [{fdep, hoconsc:mk(integer(), #{deprecated => {since, "0.1"}})}]}
    },
    ?assertEqual(
        #{<<"f1">> => 1},
        hocon_tconf:check_plain(
            Sc,
            #{<<"f1">> => 1},
            #{required => false}
        )
    ).

bad_root_test() ->
    Sc = #{
        roots => ["ab"],
        fields => #{"ab" => [{f1, hoconsc:mk(integer(), #{default => 888})}]}
    },
    Input1 = "ab=1",
    {ok, Data1} = hocon:binary(Input1),
    ?VALIDATION_ERR(
        #{reason := bad_value_for_struct},
        hocon_tconf:check_plain(Sc, Data1)
    ),
    ok.

bad_value_test() ->
    Conf = "person.id=123",
    {ok, M} = hocon:binary(Conf, #{format => richmap}),
    ?VALIDATION_ERR(
        #{reason := bad_value_for_struct},
        begin
            {Mapped, _} = hocon_tconf:map(demo_schema, M),
            Mapped
        end
    ).

no_translation_test() ->
    ConfIn = "bar={field1=w}",
    {ok, M} = hocon:binary(ConfIn, #{format => richmap}),
    {Mapped, Conf} = hocon_tconf:map(?MODULE, M),
    ?assertEqual(Mapped, hocon_tconf:translate(?MODULE, Conf, Mapped)).

no_translation2_test() ->
    Sc = #{roots => [{f1, integer()}]},
    ?assertEqual([], hocon_tconf:translate(Sc, #{}, [])).

translation_unicode_test() ->
    Sc = #{
        roots => [
            {f1, hoconsc:mk(integer())},
            {f2, hoconsc:mk(string())}
        ],
        translations => #{"tr1" => [{"路.径1", fun(_Conf) -> <<"值2"/utf8>> end}]}
    },
    {ok, Data} = hocon:binary("f1=12,f2=foo", #{format => richmap}),
    {Mapped, _Conf} = hocon_tconf:map_translate(Sc, Data, #{}),
    ?assertEqual([{tr1, [{'路', [{'径1', <<"值2"/utf8>>}]}]}], Mapped).

translation_crash_test() ->
    Sc = #{
        roots => [
            {f1, hoconsc:mk(integer())},
            {f2, hoconsc:mk(string())}
        ],
        translations => #{"tr1" => [{"f3", fun(_Conf) -> error(always) end}]}
    },
    {ok, Data} = hocon:binary("f1=12,f2=foo", #{format => richmap}),
    {Mapped, Conf} = hocon_tconf:map(Sc, Data),
    ?assertThrow(
        {_, [#{kind := translation_error, reason := always, exception := error, stacktrace := _}]},
        hocon_tconf:translate(Sc, Conf, Mapped)
    ).

translation_throw_test() ->
    Sc = #{
        roots => [
            {f1, hoconsc:mk(integer())},
            {f2, hoconsc:mk(string())}
        ],
        translations => #{"tr1" => [{"f3", fun(_Conf) -> throw(expect) end}]}
    },
    {ok, Data} = hocon:binary("f1=12,f2=foo", #{format => richmap}),
    {Mapped, Conf} = hocon_tconf:map(Sc, Data),
    ?assertThrow(
        {_, [#{kind := translation_error, reason := expect}]},
        hocon_tconf:translate(Sc, Conf, Mapped)
    ).

%% a schema module may have multiple root names (which the roots/0 returns)
%% map/2 checks maps all the roots
%% map/3 allows to pass in the names as the third arg.
%% this test is to cover map/3 API
map_just_one_root_test() ->
    Sc = #{
        roots => [root],
        fields => #{
            root => [
                {f1, hoconsc:mk(integer())},
                {f2, hoconsc:mk(string())}
            ]
        }
    },
    {ok, Data} = hocon:binary("root={f1=1,f2=bar}", #{format => richmap}),
    {[], NewData} = hocon_tconf:map(Sc, Data, [root]),
    ?assertEqual(
        #{<<"root">> => #{<<"f2">> => "bar", <<"f1">> => 1}},
        richmap_to_map(NewData)
    ).

validation_error_if_not_required_test() ->
    Sc = #{
        roots => [root],
        fields => #{
            root => [
                {f1, hoconsc:mk(integer())},
                {f2, hoconsc:mk(string())}
            ]
        }
    },
    Data = #{},
    ?VALIDATION_ERR(
        #{reason := required_field},
        hocon_tconf:check_plain(Sc, Data, #{required => true})
    ).

unknown_fields_test_() ->
    Conf = "person.id.num=123,person.name=mike",
    {ok, M} = hocon:binary(Conf, #{format => richmap}),
    ?GEN_VALIDATION_ERR(
        #{
            reason := unknown_fields,
            unmatched := none,
            unknown := "name"
        },
        hocon_tconf:map(demo_schema, M, all)
    ).

expected_fields_not_matched_test_() ->
    Conf = "\nperson.name=mike\nperson.key=foo\nperson.val=bar\n",
    {ok, M} = hocon:binary(Conf, #{format => richmap}),
    ?GEN_VALIDATION_ERR(
        #{
            reason := unknown_fields,
            unmatched := "id",
            unknown := "key,name,..."
        },
        hocon_tconf:map(demo_schema, M, all)
    ).

required_field_test() ->
    Sc = #{roots => [{f1, hoconsc:mk(integer(), #{required => true})}]},
    ?VALIDATION_ERR(
        #{reason := required_field, path := "f1"},
        hocon_tconf:check_plain(Sc, #{})
    ),
    ok.

bad_input_test() ->
    Sc = #{roots => [{f1, integer()}]},
    %% NOTE: this is not a valid richmap, intended to test a crash
    BadInput = #{?HOCON_V => #{<<"f1">> => 1}},
    ?assertError({bad_richmap, 1}, hocon_tconf:map(Sc, BadInput)).

not_array_test() ->
    Sc = #{roots => [{f1, hoconsc:array(integer())}]},
    BadInput = #{<<"f1">> => 1},
    ?VALIDATION_ERR(
        #{expected_data_type := array, got := 1},
        hocon_tconf:check_plain(Sc, BadInput)
    ),
    BadInput1 = #{<<"f1">> => <<"foo">>},
    ?VALIDATION_ERR(
        #{expected_data_type := array, got := string},
        hocon_tconf:check_plain(Sc, BadInput1)
    ).

converter_test() ->
    Sc = #{
        roots => [
            {f1,
                hoconsc:mk(
                    integer(),
                    #{
                        converter => fun
                            (<<"one">>, _) -> 1;
                            (1, #{make_serializable := true}) -> "one"
                        end
                    }
                )}
        ]
    },
    Input = #{<<"f1">> => <<"one">>},
    BadIn = #{<<"f1">> => <<"two">>},
    Converted = hocon_tconf:check_plain(Sc, Input),
    ?assertEqual(#{<<"f1">> => 1}, Converted),
    ?assertEqual(
        #{<<"f1">> => <<"one">>},
        hocon_tconf:make_serializable(Sc, Converted, #{})
    ),
    ?VALIDATION_ERR(
        #{reason := converter_crashed},
        hocon_tconf:check_plain(Sc, BadIn)
    ).

%% converter can be used to convert a value to a different type
%% From ref(bar) to map(name, ref(bar)).
converter_type_test() ->
    Sc = #{
        roots => [
            {f1,
                hoconsc:mk(
                    hoconsc:union([
                        hoconsc:ref(?MODULE, bar), hoconsc:map(name, hoconsc:ref(?MODULE, bar))
                    ]),
                    #{
                        converter => fun(Conf, _Opts) ->
                            Fields = lists:map(fun({F, _}) -> atom_to_binary(F) end, fields(bar)),
                            DefaultBar = maps:with(Fields, Conf),
                            MapBar = maps:without(Fields, Conf),
                            hocon_maps:deep_merge(MapBar, #{<<"default">> => DefaultBar})
                        end
                    }
                )}
        ]
    },
    Inputs = [
        "{f1.field1: \"foo1\"}",
        ""
        "\n"
        "        {f1 {field1: foo1\n"
        "             host: \"127.0.0.1\",\n"
        "             my-test-name: {\n"
        "                field1: \"test-name\"\n"
        "                },\n"
        "             default: {\n"
        "                field1: \"default-field1\"\n"
        "                }\n"
        "             }\n"
        "        }\n"
        "        "
        ""
    ],
    Expects = [
        #{
            <<"f1">> =>
                #{
                    <<"default">> =>
                        #{<<"field1">> => "foo1", <<"union_with_default">> => dummy}
                }
        },
        #{
            <<"f1">> =>
                #{
                    <<"default">> =>
                        #{
                            <<"field1">> => "foo1",
                            <<"union_with_default">> => dummy,
                            <<"host">> => "127.0.0.1"
                        },
                    <<"my-test-name">> =>
                        #{
                            <<"field1">> => "test-name",
                            <<"union_with_default">> => dummy
                        }
                }
        }
    ],
    lists:foreach(
        fun({Input, Expect}) ->
            {ok, PlainConf} = hocon:binary(Input, #{format => map}),
            {ok, RichConf} = hocon:binary(Input, #{format => richmap}),
            PlainConverted = hocon_tconf:check_plain(Sc, PlainConf),
            RichConverted = richmap_to_map(hocon_tconf:check(Sc, RichConf)),
            ?assertEqual(PlainConverted, RichConverted),
            ?assertEqual(Expect, PlainConverted)
        end,
        lists:zip(Inputs, Expects)
    ),
    ok.

converter_non_primitive_test() ->
    Sc = #{
        roots => [
            {f1,
                hoconsc:mk(
                    integer(),
                    #{
                        converter => fun
                            ([#{<<"one">> := true}], _) -> 1;
                            (1, _) -> [#{<<"one">> => true}]
                        end
                    }
                )}
        ]
    },
    Input = #{<<"f1">> => [#{<<"one">> => true}]},
    Converted = hocon_tconf:check_plain(Sc, Input),
    ?assertEqual(#{<<"f1">> => 1}, Converted),
    ?assertEqual(
        #{<<"f1">> => [#{<<"one">> => true}]},
        hocon_tconf:make_serializable(Sc, Converted, #{})
    ).

converter_input_undefined_test() ->
    Sc = #{
        roots => [
            {f1,
                hoconsc:mk(
                    integer(),
                    #{converter => fun(V) -> V end, required => false}
                )}
        ]
    },
    Input = #{<<"f1">> => undefined},
    ?assertEqual(#{<<"f1">> => undefined}, hocon_tconf:check_plain(Sc, Input)).

converter_return_undefined_test() ->
    Sc = #{
        roots => [
            {f1,
                hoconsc:mk(
                    integer(),
                    #{converter => fun(_V) -> undefined end, required => false}
                )}
        ]
    },
    Input = #{<<"f1">> => <<"1">>},
    %% assert that converter returning 'undefined' has no effect
    %% this is a limitation of current version:
    %% there is no way to 'remove' a config value by converting values to 'undefined'
    %% use 'deprecated' instead
    ?assertEqual(#{<<"f1">> => <<"1">>}, hocon_tconf:check_plain(Sc, Input)).

no_dot_in_root_name_test() ->
    Sc = #{
        roots => ["a.b"],
        fields => [{f1, hoconsc:mk(integer())}]
    },
    ?assertError(
        #{reason := bad_root_name, root_name := <<"a.b">>},
        hocon_schema:find_structs(Sc)
    ).

union_of_roots_test() ->
    Sc = #{
        roots => [{f1, hoconsc:union([dummy, "m1", "m2"])}],
        fields => #{
            "m1" => [{m1, integer()}],
            "m2" => [{m2, integer()}]
        }
    },
    ?assertEqual(#{f1 => #{m1 => 1}}, check_return_atom_keys(Sc, "f1.m1=1")),
    ?assertEqual(#{f1 => #{m2 => 2}}, check_return_atom_keys(Sc, "f1.m2=2")),
    ?assertEqual(#{f1 => dummy}, check_return_atom_keys(Sc, "f1=dummy")),
    ?VALIDATION_ERR(
        #{reason := matched_no_union_member},
        check_return_atom_keys(Sc, "f1=other")
    ),
    ?VALIDATION_ERR(
        #{reason := matched_no_union_member},
        check_return_atom_keys(Sc, "f1.m3=3")
    ),
    ok.

multiple_errors_test() ->
    Sc = #{roots => [{m1, integer()}, {m2, integer()}]},
    ?assertThrow(
        {_, [
            #{kind := validation_error, path := "m1"},
            #{kind := validation_error, path := "m2"}
        ]},
        check_return_atom_keys(Sc, "m1=a,m2=b")
    ),
    ok.

check_return_atom_keys(Sc, Input) ->
    {ok, Map} = hocon:binary(Input),
    hocon_tconf:check_plain(Sc, Map, #{atom_key => true}).

resolve_struct_name_test() ->
    ?assertEqual(foo, hocon_schema:resolve_struct_name(demo_schema, "foo")),
    ?assertThrow(
        {unknown_struct_name, _, "noexist"},
        hocon_schema:resolve_struct_name(demo_schema, "noexist")
    ).

sensitive_data_obfuscation_test() ->
    Sc = #{roots => [{secret, hoconsc:mk(string(), #{sensitive => true})}]},
    Self = self(),
    {ok, RichConf} = hocon:binary("secret = aaa", #{format => richmap}),
    with_envs(
        fun() ->
            hocon_tconf:check(
                Sc,
                RichConf,
                #{
                    logger => fun(_Level, Msg) -> Self ! Msg end,
                    apply_override_envs => true
                }
            ),
            receive
                #{hocon_env_var_name := "EMQX_SECRET", path := Path, value := Value} ->
                    ?assertEqual("secret", Path),
                    ?assertEqual(<<"******">>, Value)
            end
        end,
        envs([{"EMQX_SECRET", "bbb"}])
    ),
    ok.

remote_ref_test() ->
    Sc = #{
        roots => [root],
        fields => #{root => [{f1, hoconsc:ref(?MODULE, bar)}]}
    },
    {ok, Data} = hocon:binary("root={f1={field1=foo}}", #{}),
    ?assertMatch(
        #{root := #{f1 := #{field1 := "foo"}}},
        hocon_tconf:check_plain(Sc, Data, #{atom_key => true})
    ),
    ok.

local_ref_test() ->
    Input = "parent={child={name=marribay}}",
    {ok, Data} = hocon:binary(Input, #{}),
    ?assertMatch(
        #{parent := #{child := #{name := "marribay"}}},
        hocon_tconf:check_plain(?MODULE, Data, #{atom_key => true}, [parent])
    ),
    ok.

integrity_check_test() ->
    Sc = #{
        roots => [root],
        fields => #{
            root => [
                {f1, integer()},
                {f2, integer()}
            ]
        },
        validations => [
            {"f1 > f2", fun(C) ->
                F1 = hocon_maps:get("root.f1", C),
                F2 = hocon_maps:get("root.f2", C),
                F1 > F2
            end}
        ]
    },
    Data1 = "root={f1=1,f2=2}",
    ?VALIDATION_ERR(
        #{
            reason := integrity_validation_failure,
            validation_name := "f1 > f2"
        },
        check_plain_bin(Sc, Data1, #{atom_key => true})
    ),
    Data2 = "root={f1=3,f2=2}",
    ?assertEqual(
        #{root => #{f1 => 3, f2 => 2}},
        check_plain_bin(Sc, Data2, #{atom_key => true})
    ),
    ok.

integrity_crash_test() ->
    Sc = #{
        roots => [root],
        fields => #{root => [{f1, integer()}]},
        validations => [{"always-crash", fun(_) -> error(always) end}]
    },
    Data1 = "root={f1=1}",
    ?VALIDATION_ERR(
        #{
            reason := integrity_validation_crash,
            validation_name := "always-crash"
        },
        check_plain_bin(Sc, Data1, #{atom_key => true})
    ),
    ok.

integrity_throw_test() ->
    Sc = #{
        roots => [root],
        fields => #{root => [{f1, integer()}]},
        validations => [{"always-throw", fun(_) -> throw(expect) end}]
    },
    Data1 = "root={f1=1}",
    ?VALIDATION_ERR(
        #{
            reason := integrity_validation_failure,
            validation_name := "always-throw",
            result := expect
        },
        check_plain_bin(Sc, Data1, #{atom_key => true})
    ),
    ok.

check_plain_bin(Sc, Data, Opts) ->
    {ok, Conf} = hocon:binary(Data, #{}),
    hocon_tconf:check_plain(Sc, Conf, Opts).

default_value_for_array_field_test() ->
    Sc = #{
        roots => [
            {k, hoconsc:mk(hoconsc:array(string()), #{default => [<<"a">>, <<"b">>]})},
            {x, string()}
        ]
    },
    Conf = "x = y",
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(
        #{<<"k">> => ["a", "b"], <<"x">> => "y"},
        richmap_to_map(
            hocon_tconf:check(Sc, RichMap)
        )
    ).

default_value_map_field_test() ->
    Sc = #{
        roots => [
            {k, #{
                type => hoconsc:ref(sub),
                default => #{
                    <<"a">> => <<"foo">>,
                    <<"b">> => <<"bar">>
                }
            }},
            {x, string()}
        ],
        fields => #{sub => [{a, string()}, {b, string()}]}
    },
    Conf = "x = y",
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(
        #{
            <<"k">> => #{
                <<"a">> => "foo",
                <<"b">> => "bar"
            },
            <<"x">> => "y"
        },
        richmap_to_map(hocon_tconf:check(Sc, RichMap))
    ).

default_value_for_null_enclosing_struct_test() ->
    Sc = #{
        roots => [{"l1", #{type => hoconsc:ref("l2")}}],
        fields => #{
            "l2" => [
                {"l2", #{type => integer(), default => 22}},
                {"l3", #{type => integer()}}
            ]
        }
    },
    Conf = "",
    {ok, PlainMap} = hocon:binary(Conf, #{}),
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(
        #{<<"l1">> => #{<<"l2">> => 22}},
        hocon_tconf:check_plain(Sc, PlainMap, #{required => false})
    ),
    ?assertEqual(
        #{<<"l1">> => #{<<"l2">> => 22}},
        hocon_tconf:check(Sc, RichMap, #{required => false, return_plain => true})
    ).

fill_primitive_defaults_test() ->
    Sc = #{
        roots => ["a"],
        fields => #{
            "a" =>
                [
                    {b, hoconsc:mk(integer(), #{default => 888})},
                    {c,
                        hoconsc:mk(integer(), #{
                            default => "15s",
                            converter => fun(Dur) -> hocon_postprocess:duration(Dur) end
                        })},
                    {d, hoconsc:mk(integer(), #{default => <<"16">>})}
                ]
        }
    },
    ?assertMatch(
        #{<<"a">> := #{<<"b">> := 888, <<"c">> := 15000, <<"d">> := 16}},
        hocon_tconf:check_plain(Sc, #{}, #{required => false})
    ),
    ?assertMatch(
        #{<<"a">> := #{<<"b">> := 888, <<"c">> := <<"15s">>, <<"d">> := <<"16">>}},
        hocon_tconf:make_serializable(Sc, #{}, #{})
    ),
    ok.

fill_complex_defaults_test() ->
    Sc = #{
        roots => [
            {"a",
                hoconsc:mk(
                    hoconsc:ref("sub"),
                    #{default => #{<<"c">> => 2, <<"d">> => [90, 91, 92]}}
                )}
        ],
        fields => #{
            "sub" =>
                [
                    {"c", hoconsc:mk(integer())},
                    {"d", hoconsc:mk(hoconsc:array(integer()))}
                ]
        }
    },
    %% ensure integer array is not converted to a string
    ?assertMatch(
        #{<<"a">> := #{<<"c">> := 2, <<"d">> := [90, 91, 92]}},
        hocon_tconf:make_serializable(Sc, #{}, #{})
    ),
    ok.

no_default_value_fill_for_hidden_fields_test() ->
    Sc = #{
        roots => [
            {"a",
                hoconsc:mk(
                    hoconsc:ref("sub"),
                    #{
                        default => #{<<"c">> => 2, <<"d">> => [90, 91, 92]},
                        importance => ?IMPORTANCE_HIDDEN
                    }
                )}
        ],
        fields => #{
            "sub" =>
                [
                    {"c",
                        hoconsc:mk(integer(), #{
                            default => $c,
                            importance => ?IMPORTANCE_HIDDEN
                        })},
                    {"d",
                        hoconsc:mk(
                            hoconsc:array(integer()),
                            #{default => [$d]}
                        )}
                ]
        }
    },
    ?assertEqual(#{}, hocon_tconf:make_serializable(Sc, #{}, #{})),
    C1 = #{<<"a">> => #{<<"d">> => [1]}},
    ?assertEqual(C1, hocon_tconf:make_serializable(Sc, C1, #{})),
    C2 = #{<<"a">> => #{<<"c">> => 2, <<"d">> => [1]}},
    ?assertEqual(C2, hocon_tconf:make_serializable(Sc, C2, #{})),
    C3 = #{<<"a">> => #{<<"c">> => 2}},
    C4 = #{<<"a">> => #{<<"c">> => 2, <<"d">> => [$d]}},
    ?assertEqual(C4, hocon_tconf:make_serializable(Sc, C3, #{})),
    ok.

root_array_test_() ->
    Sc = #{
        roots => [{foo, hoconsc:array(hoconsc:ref(foo))}],
        fields => #{
            foo => [
                {"kling", hoconsc:mk(integer())},
                {"klang", hoconsc:mk(integer())}
            ]
        }
    },
    Conf =
        "foo = [{kling = 1, klang=2},\n"
        "                   {kling = 2, klang=4},\n"
        "                   {kling = 3, klang=6}]",
    [
        {"richmap", fun() ->
            {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
            ?assertEqual(
                #{
                    <<"foo">> => [
                        #{<<"kling">> => 1, <<"klang">> => 2},
                        #{<<"kling">> => 2, <<"klang">> => 4},
                        #{<<"kling">> => 3, <<"klang">> => 6}
                    ]
                },
                richmap_to_map(hocon_tconf:check(Sc, RichMap))
            )
        end},
        {"plainmap", fun() ->
            {ok, PlainMap} = hocon:binary(Conf, #{}),
            ?assertEqual(
                #{
                    <<"foo">> => [
                        #{<<"kling">> => 1, <<"klang">> => 2},
                        #{<<"kling">> => 2, <<"klang">> => 4},
                        #{<<"kling">> => 3, <<"klang">> => 6}
                    ]
                },
                hocon_tconf:check(Sc, PlainMap, #{format => map})
            )
        end},
        {"empty", fun() ->
            {ok, Map} = hocon:binary("foo = []", #{format => richmap}),
            ?assertEqual(
                #{<<"foo">> => []},
                richmap_to_map(
                    hocon_tconf:check(Sc, Map, #{format => richmap})
                )
            )
        end}
    ].

root_array_env_override_test_() ->
    [
        {"richmap", fun() -> test_array_env_override(richmap) end},
        {"plainmap", fun() -> test_array_env_override(map) end}
    ].

test_array_env_override(Format) ->
    Sc = #{
        roots => [{foo, hoconsc:array(hoconsc:ref(foo))}],
        fields => #{
            foo => [
                {"kling", hoconsc:mk(integer())},
                {"klang", hoconsc:mk(integer())}
            ]
        }
    },
    with_envs(
        fun() ->
            Conf = "",
            {ok, Parsed} = hocon:binary(Conf, #{format => Format}),
            Opts = #{format => Format, required => false, apply_override_envs => true},
            ?assertEqual(
                #{
                    <<"foo">> => [
                        #{<<"kling">> => 111},
                        #{<<"klang">> => 222}
                    ]
                },
                richmap_to_map(hocon_tconf:check(Sc, Parsed, Opts))
            )
        end,
        envs([{"EMQX_FOO__1__KLING", "111"}, {"EMQX_FOO__2__KLANG", "222"}])
    ).

array_env_override_ignore_test() ->
    Sc = #{
        roots => [{foo, hoconsc:array(hoconsc:ref(foo))}],
        fields => #{foo => [{"intf", hoconsc:mk(integer())}]}
    },
    with_envs(
        fun() ->
            Conf = "",
            {ok, Parsed} = hocon:binary(Conf, #{format => map}),
            Opts = #{format => map, required => false, apply_override_envs => true},
            ?assertEqual(#{}, hocon_tconf:check(Sc, Parsed, Opts))
        end,
        envs([{"EMQX_FOO__first__intf", "111"}])
    ).

bad_indexed_map_test() ->
    Sc = #{
        roots => [foo],
        fields => #{foo => [{"bar", hoconsc:mk(hoconsc:array(integer()))}]}
    },
    %% 3 missing
    Array = #{<<"1">> => 1, <<"2">> => 2, <<"4">> => 4},
    Conf = #{<<"foo">> => #{<<"bar">> => Array}},
    ?assertThrow(
        {_, [
            #{
                kind := validation_error,
                expected_index := 3,
                got_index := 4,
                path := "foo.bar"
            }
        ]},
        hocon_tconf:check(Sc, Conf, #{format => map})
    ).

fill_defaults_with_env_override_test() ->
    Sc = #{
        roots => [foo],
        fields => #{foo => [{"bar", integer()}]}
    },
    with_envs(
        fun() ->
            Conf0 = "foo={bar=121}",
            {ok, Conf} = hocon:binary(Conf0),
            Res = hocon_tconf:check_plain(Sc, Conf, #{
                make_serializable => true,
                apply_override_envs => true
            }),
            ?assertEqual(#{<<"foo">> => #{<<"bar">> => 122}}, Res)
        end,
        envs([{"EMQX_FOO__BAR", "122"}])
    ).

fill_defaults_array_test() ->
    Union = hoconsc:union([integer(), string()]),
    Sc = #{
        roots => [foo],
        fields => #{
            foo => [
                {"bar", #{
                    type => hoconsc:array(Union),
                    default => [<<"str">>]
                }},
                {"baz", #{type => integer()}}
            ]
        }
    },
    Conf0 = "foo={baz=121}",
    {ok, Conf} = hocon:binary(Conf0),
    Res = hocon_tconf:check_plain(Sc, Conf, #{
        make_serializable => true,
        apply_override_envs => true
    }),
    ?assertEqual(#{<<"foo">> => #{<<"baz">> => 121, <<"bar">> => [<<"str">>]}}, Res).

array_env_override_test_() ->
    Sc = #{
        roots => [foo],
        fields => #{
            foo => [
                {"bar", hoconsc:mk(hoconsc:array(integer()))},
                {"quu", hoconsc:mk(hoconsc:array(string()))}
            ]
        }
    },
    EnvsFooBar13 = envs([{"EMQX_FOO__BAR__1", "1"}, {"EMQX_FOO__BAR__3", "3"}]),
    [
        {"richmap", fun() -> test_array_env_override_t2(Sc, richmap) end},
        {"plainmap", fun() -> test_array_env_override_t2(Sc, map) end},
        {"bad_sequence", fun() ->
            ?assertError(
                {bad_array_index, "EMQX_FOO__BAR__3"},
                test_array_override(Sc, map, EnvsFooBar13)
            ),
            Envs = EnvsFooBar13 ++ [{"EMQX_FOO__BAR__10", "10"}],
            ?assertError(
                {bad_array_index, "EMQX_FOO__BAR__10"},
                test_array_override(Sc, map, Envs)
            )
        end},
        {"bad_indexed_map", fun() ->
            Conf1 = "",
            Envs = envs([{"EMQX_FOO__BAR", "1"}]),
            Throw1 = test_array_override(Sc, richmap, Envs, Conf1),
            ?assertMatch(
                [#{kind := validation_error, expected_data_type := array, got := 1}], Throw1
            ),
            Conf2 = "foo : {bar : [0, 2, 0]}",
            Throw2 = test_array_override(Sc, richmap, Envs, Conf2),
            ?assertEqual(Throw1, Throw2),
            Throw3 = test_array_override(Sc, map, Envs, Conf2),
            ?assertEqual(Throw1, Throw3)
        end},
        {"override_parsed_array_plain", fun() ->
            Conf = <<"foo : {bar : [0, 2, 0]}">>,
            Checked = test_array_override(Sc, map, EnvsFooBar13, Conf),
            ?assertEqual(#{<<"foo">> => #{<<"bar">> => [1, 2, 3]}}, Checked)
        end},
        {"override_parsed_array_rich", fun() ->
            Conf = <<"foo : {bar : [0, 2, 0]}">>,
            Checked = test_array_override(Sc, richmap, EnvsFooBar13, Conf),
            ?assertEqual(
                #{<<"foo">> => #{<<"bar">> => [1, 2, 3]}},
                richmap_to_map(Checked)
            )
        end},
        {"override_parsed_non-array_plain", fun() ->
            Conf = <<"foo : {bar : 22}">>,
            Envs = envs([{"EMQX_FOO__BAR__1", "1"}]),
            Checked = test_array_override(Sc, map, Envs, Conf),
            ?assertEqual(#{<<"foo">> => #{<<"bar">> => [1]}}, Checked)
        end},
        {"override_parsed_non-array_rich", fun() ->
            Conf = <<"foo : {bar : notarray}">>,
            Envs = envs([{"EMQX_FOO__BAR__1", "1"}]),
            Checked = test_array_override(Sc, richmap, Envs, Conf),
            ?assertEqual(
                #{<<"foo">> => #{<<"bar">> => [1]}},
                richmap_to_map(Checked)
            )
        end}
    ].

envs(Envs) -> [{"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"} | Envs].

test_array_override(Sc, Format, Envs) ->
    test_array_override(Sc, Format, Envs, <<"">>).

test_array_override(Sc, Format, Envs, Conf) ->
    with_envs(
        fun() ->
            {ok, Parsed} = hocon:binary(Conf, #{format => Format}),
            Opts = #{
                format => Format,
                required => false,
                apply_override_envs => true
            },
            try
                hocon_tconf:check(Sc, Parsed, Opts)
            catch
                throw:{_Sc, R} -> R
            end
        end,
        Envs
    ).

test_array_env_override_t2(Sc, Format) ->
    with_envs(
        fun() ->
            {ok, Parsed} = hocon:binary(<<>>, #{format => Format}),
            Opts = #{format => Format, required => false, apply_override_envs => true},
            ?assertEqual(
                #{
                    <<"foo">> => #{
                        <<"bar">> => [2, 1],
                        <<"quu">> => ["quu"]
                    }
                },
                richmap_to_map(hocon_tconf:check(Sc, Parsed, Opts))
            )
        end,
        envs([{"EMQX_FOO__bar__1", "2"}, {"EMQX_FOO__bar__2", "1"}, {"EMQX_FOO__quu__1", "quu"}])
    ).

ref_required_test() ->
    Sc = #{
        roots => [
            {k, #{
                type => hoconsc:ref(sub),
                required => {false, recursively}
            }},
            {x, string()}
        ],
        fields => #{sub => [{a, string()}, {b, string()}]}
    },
    Conf = "x = y",
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(
        #{<<"x">> => "y"},
        richmap_to_map(hocon_tconf:check(Sc, RichMap))
    ),
    {ok, Map} = hocon:binary("k = null, x = y", #{format => map}),
    ?assertEqual(#{<<"x">> => "y"}, hocon_tconf:check_plain(Sc, Map)),
    with_envs(
        fun() ->
            Opts = #{apply_override_envs => true},
            {ok, Map2} = hocon:binary("k = {a: a, b: b}, x = y", #{format => map}),
            ?assertEqual(#{<<"x">> => "y"}, hocon_tconf:check_plain(Sc, Map2, Opts))
        end,
        envs([{"EMQX_K", "null"}])
    ).

lazy_test() ->
    Sc = #{
        roots => [
            {k, #{type => hoconsc:lazy(integer())}},
            {x, string()}
        ]
    },
    Conf = "x = y, k=whatever",
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(
        #{<<"x">> => "y", <<"k">> => <<"whatever">>},
        richmap_to_map(hocon_tconf:check(Sc, RichMap))
    ).

lazy_root_test() ->
    Sc = #{
        roots => [{foo, hoconsc:lazy(hoconsc:ref(foo))}],
        fields => #{
            foo => [
                {k, #{type => integer()}},
                {x, string()}
            ]
        }
    },
    Conf = "foo = {x = y, k=whatever}",
    {ok, RichMap} = hocon:binary(Conf, #{format => richmap}),
    ?assertEqual(
        #{<<"foo">> => #{<<"x">> => <<"y">>, <<"k">> => <<"whatever">>}},
        richmap_to_map(hocon_tconf:check(Sc, RichMap))
    ).

lazy_root_env_override_test() ->
    Sc = #{
        roots => [{foo, hoconsc:lazy(hoconsc:ref(bar))}],
        fields => fun(bar) ->
            [
                {"kling", hoconsc:mk(integer())},
                {"klang", hoconsc:mk(integer())}
            ]
        end
    },
    with_envs(
        fun() ->
            Conf = "foo = {kling = 1}",
            {ok, PlainMap} = hocon:binary(Conf, #{}),
            Opts = #{format => map, required => false, apply_override_envs => true},
            ?assertEqual(
                #{<<"foo">> => #{<<"kling">> => 1}},
                hocon_tconf:check(Sc, PlainMap, Opts)
            ),
            ?assertEqual(
                #{
                    <<"foo">> => #{
                        <<"kling">> => 111,
                        <<"klang">> => 222
                    }
                },
                hocon_tconf:check(Sc, PlainMap, Opts#{check_lazy => true})
            )
        end,
        envs([{"EMQX_FOO__KLING", "111"}, {"EMQX_FOO__KLANG", "222"}])
    ).

duplicated_root_names_test() ->
    Sc = #{roots => [foo, bar, foo]},
    ?assertError(
        {duplicated_root_names, [<<"foo">>]},
        hocon_schema:roots(Sc)
    ).

union_converter_test() ->
    Sc = #{
        roots => [foo],
        fields =>
            #{
                foo => [
                    {bar, #{
                        type => ?UNION([string(), {array, string()}]),
                        default => <<"2,3">>,
                        converter => fun
                            (B) when is_binary(B) ->
                                binary:split(B, <<",">>, [global]);
                            (L) when is_list(L) ->
                                L
                        end
                    }}
                ]
            }
    },
    Checked = hocon_tconf:check_plain(
        Sc,
        #{<<"foo">> => #{<<"bar">> => <<"1,2">>}},
        #{atom_key => true}
    ),
    ?assertEqual(#{foo => #{bar => ["1", "2"]}}, Checked).

list_converter_test() ->
    Sc = #{
        roots => [foo],
        fields =>
            #{
                foo => [
                    {bar, #{
                        type => list(),
                        default => #{a => b},
                        converter => fun(Map) -> maps:to_list(Map) end
                    }}
                ]
            }
    },
    Checked = hocon_tconf:check_plain(
        Sc,
        #{<<"foo">> => #{<<"bar">> => #{<<"a">> => <<"c">>}}},
        #{atom_key => true}
    ),
    ?assertEqual(#{foo => #{bar => [{<<"a">>, <<"c">>}]}}, Checked).

singleton_type_test() ->
    Sc = #{
        roots => [foo],
        fields =>
            #{foo => [{bar, bar}]}
    },
    ?assertEqual(
        #{foo => #{bar => bar}},
        hocon_tconf:check_plain(
            Sc,
            #{<<"foo">> => #{<<"bar">> => <<"bar">>}},
            #{atom_key => true}
        )
    ).

non_primitive_value_validation_test() ->
    Sc = fun(MinLen) ->
        #{
            roots => [
                {foo, #{
                    type => {array, integer()},
                    validator => fun(Arr) -> length(Arr) >= MinLen end
                }}
            ],
            fields => #{}
        }
    end,
    ?assertEqual(
        #{foo => [1, 2]},
        hocon_tconf:check_plain(Sc(2), #{<<"foo">> => [1, 2]}, #{atom_key => true})
    ),
    ?assertThrow(
        {_, [#{kind := validation_error, reason := returned_false}]},
        hocon_tconf:check_plain(Sc(3), #{<<"foo">> => [1, 2]}, #{atom_key => true})
    ),
    ok.

override_env_with_include_test() ->
    Sc = #{
        roots => [{foo, hoconsc:ref(bar)}],
        fields => fun(bar) ->
            [
                {"kling", hoconsc:mk(integer())},
                {"klang", hoconsc:mk(integer())}
            ]
        end
    },
    with_envs(
        fun() ->
            Conf = "foo = {kling = 1}",
            {ok, PlainMap} = hocon:binary(Conf, #{}),
            Opts = #{format => map, required => false, apply_override_envs => true},
            ?assertEqual(
                #{
                    <<"foo">> => #{
                        <<"kling">> => 1,
                        <<"klang">> => 233
                    }
                },
                hocon_tconf:check(Sc, PlainMap, Opts#{check_lazy => true})
            )
        end,
        envs([{"EMQX_FOO", "{include \"etc/klingklang.conf\"}"}])
    ).

override_env_with_include_abs_path_test() ->
    Sc = #{
        roots => [{foo, hoconsc:ref(bar)}],
        fields => fun(bar) ->
            [
                {"kling", hoconsc:mk(integer())},
                {"klang", hoconsc:mk(integer())}
            ]
        end
    },
    Content = "kling=123,\nklang=456",
    Include = "/tmp/hocon_override_env_with_include_abs_path_test",
    ok = file:write_file(Include, Content),
    with_envs(
        fun() ->
            Conf = "foo = {kling = 1}",
            {ok, PlainMap} = hocon:binary(Conf, #{apply_override_envs => true}),
            Opts = #{format => map, required => false, apply_override_envs => true},
            ?assertEqual(
                #{
                    <<"foo">> => #{
                        <<"kling">> => 123,
                        <<"klang">> => 456
                    }
                },
                hocon_tconf:check(Sc, PlainMap, Opts#{
                    check_lazy => true,
                    apply_override_envs => true
                })
            )
        end,
        envs([{"EMQX_FOO", "{include \"" ++ Include ++ "\"}"}])
    ).

redundant_id_converter(#{<<"type">> := Type, <<"backend">> := Backend} = Conf) ->
    ExpectedID = iolist_to_binary([Type, ":", Backend]),
    case maps:get(<<"id">>, Conf, undefined) of
        undefined -> Conf#{<<"id">> => ExpectedID};
        Id when Id =:= ExpectedID -> Conf;
        Other -> throw({invalid_id, Other})
    end.

redundant_field_test() ->
    Sc = #{
        roots => [
            {foo,
                hoconsc:mk(
                    hoconsc:ref(foo),
                    #{converter => fun redundant_id_converter/1}
                )}
        ],
        fields => fun(foo) ->
            [
                {id, hoconsc:mk(string(), #{required => false})},
                {type, string()},
                {backend, string()}
            ]
        end
    },
    Opts = #{format => map, atom_key => true},
    Conf1 = "foo = {id = \"a:b\", type = a, backend = b}",
    {ok, Conf1Map} = hocon:binary(Conf1, #{}),
    Expected1 = #{
        foo => #{
            id => "a:b",
            type => "a",
            backend => "b"
        }
    },
    ?assertEqual(Expected1, hocon_tconf:check(Sc, Conf1Map, Opts)),
    Conf2 = "foo = {type = a, backend = b}",
    {ok, Conf2Map} = hocon:binary(Conf2, #{}),
    ?assertEqual(Expected1, hocon_tconf:check(Sc, Conf2Map, Opts)),
    Conf3 = "foo = {id = \"a:c\", type = a, backend = b}",
    {ok, Conf3Map} = hocon:binary(Conf3, #{}),
    ?assertThrow(
        {_, [#{reason := {invalid_id, <<"a:c">>}}]},
        hocon_tconf:check(Sc, Conf3Map, Opts)
    ),
    ok.

%% Make a union type schema which has a member foo and a member bar  (both are structs)
%% each union struct has a "type" field which can be used to select type with a given map() value.
%% e.g. if "type = foo" is in the value, then the 'foo' type struct is to be selected
%% if "type = bar" is found in the value, then the 'bar' type struct is to be selected
foo_bar_union_sc() ->
    UnionMembers =
        #{
            <<"foo">> => hoconsc:ref(foo),
            <<"bar">> => hoconsc:ref(bar)
        },
    UnionMemberSelector =
        fun
            (all_union_members) ->
                maps:values(UnionMembers);
            ({value, #{<<"type">> := Type}}) ->
                [maps:get(Type, UnionMembers)]
        end,
    Fields = fun(Which) ->
        [
            {type, binary()},
            {Which ++ "_bool", boolean()},
            {backend, hoconsc:mk(binary(), #{default => Which ++ "_backend"})}
        ]
    end,
    #{
        roots => [
            {"foo_or_bar", hoconsc:union(UnionMemberSelector)}
        ],
        fields => fun
            (foo) -> Fields("foo");
            (bar) -> Fields("bar")
        end
    }.

select_union_members_check_test_() ->
    Sc = foo_bar_union_sc(),
    CheckPlain = fun(Txt) ->
        Opts = #{format => map},
        {ok, Conf} = hocon:binary(Txt, Opts),
        try
            Res = hocon_tconf:check_plain(Sc, Conf),
            %% assert that make_serializable should populate default values too
            ?assertEqual(Res, hocon_tconf:make_serializable(Sc, Conf, #{})),
            Res
        catch
            throw:{_, Errors} ->
                throw({check_error, hd(Errors)})
        end
    end,
    CheckRich = fun(Txt) ->
        Opts = #{format => richmap},
        {ok, Conf} = hocon:binary(Txt, Opts),
        try
            Res = hocon_tconf:check(Sc, Conf, Opts),
            hocon_maps:ensure_plain(Res)
        catch
            throw:{_, Errors} ->
                throw({check_error, hd(Errors)})
        end
    end,
    Check = fun(Txt) ->
        try
            Res = CheckPlain(Txt),
            ?assertEqual(Res, CheckRich(Txt)),
            Res
        catch
            throw:{check_error, E} ->
                ?assertThrow({check_error, E}, CheckRich(Txt)),
                erlang:throw(E)
        end
    end,
    [
        {"match type foo", fun() ->
            ?assertMatch(
                #{
                    <<"foo_or_bar">> :=
                        #{
                            <<"type">> := <<"foo">>,
                            <<"foo_bool">> := true,
                            <<"backend">> := <<"foo_backend">>
                        }
                },
                Check("foo_or_bar = {type = foo, foo_bool = true}")
            )
        end},
        {"match type bar", fun() ->
            ?assertMatch(
                #{
                    <<"foo_or_bar">> :=
                        #{
                            <<"type">> := <<"bar">>,
                            <<"bar_bool">> := true,
                            <<"backend">> := <<"bar_backend">>
                        }
                },
                Check("foo_or_bar = {type = bar, bar_bool = true}")
            )
        end},
        {"match type bar but invalid", fun() ->
            ?assertThrow(
                #{
                    matched_type := "bar",
                    unknown := "foo_bool"
                },
                Check("foo_or_bar = {type = bar, foo_bool = true}")
            )
        end},
        {"match type foo but invalid", fun() ->
            ?assertThrow(
                #{
                    matched_type := "foo",
                    unknown := "bar_bool"
                },
                Check("foo_or_bar = {type = foo, bar_bool = true}")
            )
        end}
    ].

nullable_union_test() ->
    Structs = #{foo => [{id, hoconsc:mk(integer(), #{default => 12})}]},
    Union = hoconsc:union([hoconsc:ref(foo), bar]),
    Sc = #{
        roots => [{"root", hoconsc:mk(Union, #{required => false})}],
        fields => Structs
    },
    ?assertEqual(
        #{<<"root">> => bar},
        hocon_tconf:check_plain(Sc, #{<<"root">> => <<"bar">>})
    ),
    ?assertEqual(
        #{<<"root">> => #{<<"id">> => 12}},
        hocon_tconf:check_plain(Sc, #{})
    ),
    ok.

richmap_to_map(Map) ->
    hocon_util:richmap_to_map(Map).

convert_undefined_test() ->
    Sc = #{
        roots => [
            {"root",
                hoconsc:mk(
                    string(),
                    #{
                        required => false,
                        converter => fun(undefined, _) ->
                            <<"string">>
                        end
                    }
                )}
        ],
        fields => #{}
    },
    {ok, RichMap} = hocon:binary("{}", #{format => richmap}),
    Res = hocon_tconf:check(Sc, RichMap),
    ?assertEqual(#{<<"root">> => "string"}, hocon_maps:ensure_plain(Res)),
    ok.

convert_map_test() ->
    %% this converter only works for the map
    %% but not the map value
    Converter = fun(#{<<"name1">> := <<"foo1">>}) ->
        #{<<"name1">> => <<"foo2">>}
    end,
    Sc = #{
        roots => [
            {"root",
                hoconsc:mk(
                    hoconsc:map("name", string()),
                    #{
                        converter => Converter
                    }
                )}
        ],
        fields => #{}
    },
    {ok, Map} = hocon:binary("root = {name1 = foo1}", #{format => map}),
    Res = hocon_tconf:check_plain(Sc, Map),
    ?assertEqual(#{<<"root">> => #{<<"name1">> => "foo2"}}, Res).

map_atom_keys_test_() ->
    Sc = #{
        roots => [
            {"root", hoconsc:mk(hoconsc:map(name, hoconsc:ref(foo)), #{})}
        ],
        fields =>
            #{foo => [{foo, hoconsc:mk(map(), #{})}]}
    },
    Map0 = #{
        <<"root">> =>
            #{
                <<"name1">> =>
                    #{
                        <<"foo">> =>
                            #{
                                <<"key1">> => <<"value">>,
                                <<"key2">> => 10,
                                <<"key3">> =>
                                    #{
                                        <<"deep">> => <<"map">>,
                                        <<"deeper">> => [#{<<"struct">> => true}]
                                    }
                            }
                    }
            }
    },
    RandomKey0 = random_key(),
    RandomKey1 = random_key(),
    Map1 = #{
        <<"root">> =>
            #{
                RandomKey0 =>
                    #{<<"foo">> => #{}}
            }
    },
    Map2 = #{
        <<"root">> =>
            #{
                RandomKey1 =>
                    #{
                        <<"foo">> => #{
                            <<"key1">> => true,
                            <<"key2">> => #{
                                <<"deep">> => <<"map">>,
                                <<"deeper">> => [#{<<"struct">> => true}]
                            }
                        }
                    }
            }
    },
    %% ensure atoms exist before checking
    _ = [name1],
    [
        ?_assertEqual(
            #{
                root =>
                    #{
                        name1 =>
                            #{
                                foo => #{
                                    <<"key1">> => <<"value">>,
                                    <<"key2">> => 10,
                                    <<"key3">> => #{
                                        <<"deep">> => <<"map">>,
                                        <<"deeper">> => [#{<<"struct">> => true}]
                                    }
                                }
                            }
                    }
            },
            hocon_tconf:check_plain(Sc, Map0, #{atom_key => true})
        ),
        {"nonexistent atom",
            ?_assertError(
                #{exception := {non_existing_atom, _}},
                hocon_tconf:check_plain(Sc, Map1, #{atom_key => true})
            )},
        %% this one doesn't need the atom to exist prior to checking
        {"nonexistent atom key + unsafe",
            ?_test(begin
                Res = hocon_tconf:check_plain(
                    Sc,
                    Map2,
                    #{atom_key => {true, unsafe}}
                ),
                ?assertMatch(#{root := #{}}, Res),
                #{root := M} = Res,
                [{K, V}] = maps:to_list(M),
                ?assert(is_atom(K)),
                ?assertEqual(RandomKey1, atom_to_binary(K, utf8)),
                ?assertEqual(
                    #{
                        foo => #{
                            <<"key1">> => true,
                            <<"key2">> => #{
                                <<"deep">> => <<"map">>,
                                <<"deeper">> => [#{<<"struct">> => true}]
                            }
                        }
                    },
                    V
                )
            end)},
        {"key length > 255 bytes (atom_key = true)",
            ?_test(begin
                BadKeyStr = lists:duplicate(256, $a),
                BadKey = list_to_binary(BadKeyStr),
                BadMap = #{<<"root">> => #{BadKey => #{<<"foo">> => #{}}}},
                ?assertThrow(
                    {_, [
                        #{
                            kind := validation_error,
                            got := [BadKeyStr],
                            reason := invalid_map_key
                        }
                    ]},
                    hocon_tconf:check_plain(
                        Sc,
                        BadMap,
                        #{atom_key => true}
                    )
                )
            end)},
        {"key length > 255 bytes (atom_key = {true, unsafe})",
            ?_test(begin
                BadKeyStr = lists:duplicate(256, $a),
                BadKey = list_to_binary(BadKeyStr),
                BadMap = #{<<"root">> => #{BadKey => #{<<"foo">> => #{}}}},
                ?assertThrow(
                    {_, [
                        #{
                            kind := validation_error,
                            got := [BadKeyStr],
                            reason := invalid_map_key
                        }
                    ]},
                    hocon_tconf:check_plain(
                        Sc,
                        BadMap,
                        #{atom_key => {true, unsafe}}
                    )
                )
            end)},
        {"key length > 255 bytes (atom_key = false)",
            ?_test(begin
                BadKeyStr = lists:duplicate(256, $a),
                BadKey = list_to_binary(BadKeyStr),
                BadMap = #{<<"root">> => #{BadKey => #{<<"foo">> => #{}}}},
                ?assertMatch(
                    #{<<"root">> := #{BadKey := _}},
                    hocon_tconf:check_plain(
                        Sc,
                        BadMap,
                        #{atom_key => false}
                    )
                )
            end)}
    ].

random_key() ->
    Bytes = crypto:strong_rand_bytes(10),
    Key0 = base64:encode(Bytes),
    iolist_to_binary(re:replace(Key0, <<"[^-a-zA-Z0-9_]">>, <<>>, [global])).
