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

-module(hocon_tests).

-include_lib("eunit/include/eunit.hrl").
-include("hocon_private.hrl").

%% try to load all sample files
%% expect no crash
sample_files_test_() ->
    Wildcard = filename:join([code:lib_dir(hocon), "sample-configs", "*.conf"]),
    [
        begin
            BaseName = filename:basename(F, ".conf"),
            Json = filename:join([
                code:lib_dir(hocon),
                "sample-configs",
                "json",
                BaseName ++ ".conf.json"
            ]),
            {BaseName, fun() ->
                test_interop(BaseName, F, Json),
                test_file_load(BaseName, F)
            end}
        end
     || F <- filelib:wildcard(Wildcard)
    ].
%% include file() is not supported.
test_file_load("file-include", F) ->
    ?assertMatch({error, {scan_error, _}}, hocon:load(F));
%% unquoted string starting by null is not allowed.
test_file_load("test01", F) ->
    ?assertMatch({error, {parse_error, _}}, hocon:load(F));
%% includes test01
test_file_load("include-from-list", F) ->
    ?assertMatch({error, {parse_error, _}}, hocon:load(F));
%% do not allow quoted variable name.
test_file_load("test02" ++ _, F) ->
    ?assertMatch({error, {scan_error, _}}, hocon:load(F));
test_file_load("cycle" ++ _, F) ->
    ?assertMatch({error, {cycle, _}}, hocon:load(F));
test_file_load("test13-reference-bad-substitutions", F) ->
    ?assertMatch([["<<\"b\">>", "1", "test13-reference-bad-substitutions.conf"]], re_error(F));
% include "test01" is not allowed.
test_file_load("test03", F) ->
    ?assertMatch({error, {scan_error, _}}, hocon:load(F));
test_file_load("test03-included", F) ->
    ?assertMatch([["<<\"bar\">>", "9", "test03-included.conf"]], re_error(F));
test_file_load("test05", F) ->
    ?assertMatch({error, {scan_error, _}}, hocon:load(F));
test_file_load("test07", F) ->
    ?assertMatch({ok, #{}}, hocon:load(F));
test_file_load("test08", F) ->
    ?assertMatch({ok, #{}}, hocon:load(F));
test_file_load("test10", F) ->
    ?assertEqual(
        {ok, #{
            <<"bar">> =>
                #{
                    <<"nested">> =>
                        #{
                            <<"a">> => #{<<"c">> => 3, <<"q">> => 10},
                            <<"b">> => 5,
                            <<"c">> =>
                                #{
                                    <<"d">> => 600,
                                    <<"e">> => #{<<"c">> => 3, <<"q">> => 10},
                                    <<"f">> => 5,
                                    <<"q">> => 10
                                },
                            <<"x">> => #{<<"q">> => 10},
                            <<"y">> => 5
                        }
                },
            <<"foo">> =>
                #{
                    <<"a">> => #{<<"c">> => 3, <<"q">> => 10},
                    <<"b">> => 5,
                    <<"c">> => #{
                        <<"d">> => 600,
                        <<"e">> => #{<<"c">> => 3, <<"q">> => 10},
                        <<"f">> => 5,
                        <<"q">> => 10
                    },
                    <<"x">> => #{<<"q">> => 10},
                    <<"y">> => 5
                }
        }},
        hocon:load(F)
    );
test_file_load(_Name, F) ->
    ?assertMatch({ok, _}, hocon:load(F)).

% hoc2js converts 8.0 to 8
test_interop("test04", Conf, Json) ->
    case hocon:load(Conf) of
        {error, _} ->
            ok;
        {ok, Res} ->
            IntRes = hocon:deep_merge(Res, #{
                <<"akka">> =>
                    #{
                        <<"actor">> =>
                            #{
                                <<"default-dispatcher">> =>
                                    #{
                                        <<"core-pool-size-factor">> => 8,
                                        <<"max-pool-size-factor">> => 8
                                    }
                            }
                    }
            }),
            ?assertEqual(hocon:load(Json), {ok, IntRes})
    end;
% hoc2js does not support include syntax
test_interop("include-from-list", _, _) ->
    ok;
test_interop("test01", _, _) ->
    ok;
test_interop("test07", _, _) ->
    ok;
test_interop("test08", _, _) ->
    ok;
test_interop("test10", _, _) ->
    ok;
test_interop(_, Conf, Json) ->
    case hocon:load(Conf) of
        {error, _} ->
            ok;
        Res ->
            ?assertEqual(hocon:load(Json), Res)
    end.

read_test() ->
    {error, {enoent, F}} = hocon:load("notexist.conf"),
    Base = filename:basename(F),
    ?assertEqual("notexist.conf", Base).

symlink_cycle_test() ->
    ?assertEqual(
        {error, {cycle, ["sample-configs/cycle.conf"]}},
        hocon:load("etc/symlink-to-cycle.conf")
    ).

commas_test_() ->
    [
        ?_assertEqual(binary("a=[1,2,3]"), binary("a=[1,2,3,]")),
        ?_assertEqual(binary("a=[1,2,3]"), binary("a=[1\n2\n3]")),
        ?_assertError(_, binary("a=[1,2,3,,]")),
        ?_assertError(_, binary("a=[,1,2,3]")),
        ?_assertError(_, binary("a=[1,,2,3]")),
        ?_assertEqual(binary("a={b=1, c=2}"), binary("a={b=1, c=2,}")),
        ?_assertEqual(binary("a={b=1, c=2}"), binary("a={b=1\nc=2}")),
        ?_assertError(_, binary("a={b=1,c=2,,}")),
        ?_assertError(_, binary("a={,b=1,c=2}")),
        ?_assertError(_, binary("a={b=1,,c=2}")),
        ?_assertEqual(#{}, binary("")),
        ?_assertEqual(#{}, binary("{}"))
    ].

trailing_comma_test_() ->
    [
        ?_assertEqual(
            {ok, #{
                <<"a">> => [#{<<"b">> => 1}, #{<<"c">> => 2}],
                <<"b">> => [<<"c">>, <<"d">>]
            }},
            hocon:load("etc/trailing-comma.conf")
        )
    ].

object_merging_test_() ->
    [
        ?_assertEqual(binary("a={b=1, c=2}"), binary("a={b=1}, a={c=2}")),
        ?_assertEqual(binary("a={b=1, c=2}"), binary("a={b=1, c=1}, a={c=2}")),
        ?_assertEqual(binary("a={c=2}"), binary("a={b=1, c=1}, a=a, a={c=2}"))
    ].

unquoted_test_() ->
    [
        ?_assertEqual(#{<<"a">> => true}, binary("a=true")),
        ?_assertEqual(#{<<"a">> => false}, binary("a=false")),
        ?_assertEqual(#{<<"a">> => null}, binary("a=null"))
    ].

escape_test_() ->
    [
        ?_assertEqual(
            #{<<"str_a">> => <<"1">>},
            binary("str_a = \"1\"")
        ),
        ?_assertEqual(
            #{<<"str_b">> => <<"key=\"val\"">>},
            binary("str_b = \"key=\\\"val\\\"\"")
        ),
        ?_assertEqual(
            #{<<"str_b">> => <<" key=\"val\" ">>},
            binary("str_b = \" key=\\\"val\\\" \"")
        )
    ].

multiline_string_test_() ->
    [].

obj_inside_array_test_() ->
    [
        ?_assertEqual(#{<<"a">> => [#{<<"b">> => #{<<"c">> => 1}}]}, binary("a:[{b.c = 1}]")),
        ?_assertEqual(
            #{<<"a">> => [#{<<"b">> => #{<<"c">> => [#{<<"x">> => #{<<"y">> => 1}}]}}]},
            binary("a:[{b.c = [{x.y=1}]}]")
        )
    ].

array_concat_test_() ->
    [
        ?_assertEqual(#{<<"a">> => [1, 2, 3, 4]}, binary("a=[1, 2] [3, 4]")),
        ?_assertEqual(#{<<"a">> => [1, 2, 3, 4]}, binary("a=[1, 2][3, 4]")),
        ?_assertEqual(#{<<"a">> => [1, 2, 3, 4]}, binary("a=[1, 2,][3, 4]")),
        ?_assertEqual(#{<<"a">> => [1, 2, 3, 4]}, binary("a=[1, 2, ][3, 4]")),
        ?_assertEqual(#{<<"a">> => [1, 2, 3, 4]}, binary("a=[1, 2, \n][3, 4]")),
        ?_assertEqual(
            #{<<"x">> => [1, 2], <<"y">> => [1, 2, 1, 2]},
            binary("x=[1,2],y=${x}[1,2]")
        ),
        ?_assertEqual(
            #{<<"x">> => [1, 2], <<"y">> => [[1, 2], [1, 2]]},
            binary("x=[1,2],y=[${x},[1,2]]")
        ),
        ?_assertEqual(
            #{<<"a">> => #{<<"x">> => [1, 2, <<"str">>, #{<<"a">> => 1}]}},
            binary("a={x=[1,2,str][{a=1}]}")
        ),
        ?_assertEqual(
            #{<<"z">> => [#{<<"a">> => 1, <<"b">> => 1}, #{<<"c">> => 1}]},
            binary("z=[{a=1}{b=1}, {c=1}]")
        ),
        ?_assertEqual(#{<<"x">> => #{<<"a">> => 1, <<"b">> => 1}}, binary("x={a=1} {b=${x.a}}")),
        ?_assertEqual(#{<<"x">> => #{<<"a">> => 1, <<"b">> => 1}}, binary("x={a=${x.b}} {b=1}")),
        ?_assertEqual(#{<<"x">> => #{<<"a">> => 1, <<"b">> => 1}}, binary("x={a=${x.b} b=1}")),
        ?_assertEqual(
            #{<<"x">> => #{<<"a">> => #{<<"p">> => 1, <<"q">> => 1}, <<"b">> => 1}},
            binary("x={a={p=${x.a.q}, q=${x.b}} b=1}")
        )
    ].

object_concat_test_() ->
    [
        ?_assertEqual(#{<<"a">> => #{<<"b">> => 1, <<"c">> => 2}}, binary("a={b=1} {c=2}")),
        ?_assertEqual(#{<<"a">> => #{<<"b">> => 1, <<"c">> => 2}}, binary("a={b=1}{c=2}")),
        ?_assertEqual(#{<<"a">> => #{<<"b">> => 1, <<"c">> => 2}}, binary("a={b=1,}{c=2}")),
        ?_assertEqual(
            #{<<"a">> => #{<<"b">> => 1, <<"c">> => 2}, <<"x">> => #{<<"c">> => 2}},
            binary("x={c=2},a={b=1,}${x}")
        ),
        ?_assertEqual(
            #{<<"a">> => #{<<"b">> => 1, <<"c">> => 2}, <<"x">> => #{<<"c">> => 2}},
            binary("x={c=2},a={b=1, }${x}")
        ),
        ?_assertEqual(
            #{<<"a">> => #{<<"b">> => 1, <<"c">> => 2}, <<"x">> => #{<<"c">> => 2}},
            binary("x={c=2},a={b=1,\n}${x}")
        ),
        ?_assertEqual(
            #{
                <<"a">> => #{<<"x">> => 1, <<"y">> => 2},
                <<"b">> => #{<<"x">> => 1, <<"y">> => 2, <<"z">> => 0}
            },
            binary("a={x=1,y=2},b={x=0,y=0,z=0}${a}")
        ),
        ?_assertEqual(
            #{
                <<"a">> => #{<<"x">> => 1, <<"y">> => 2},
                <<"b">> => #{<<"x">> => 0, <<"y">> => 0, <<"z">> => 0}
            },
            binary("a={x=1,y=2},b=${a}{x=0,y=0,z=0}")
        ),
        ?_assertEqual(
            #{<<"a">> => #{<<"x">> => [1, 2, #{<<"a">> => 1}]}},
            binary("a={x=[1,2,{a:1}]}")
        )
    ].

string_concat_test_() ->
    [
        ?_assertEqual(#{<<"a">> => <<"foobar">>}, binary("a=foo\"bar\"")),
        ?_assertEqual(#{<<"a">> => <<"foobar">>, <<"x">> => <<"foo">>}, binary("x=foo,a=${x}bar"))
    ].

float_point_test_() ->
    [
        ?_assertEqual(#{<<"a">> => 0.5}, binary("a=0.5")),
        ?_assertEqual(#{<<"a">> => 0.5}, binary("a=.5")),
        ?_assertEqual(#{<<"a">> => 1.5}, binary("a=1.5"))
    ].

look_forward_test_() ->
    [
        ?_assertEqual(
            #{<<"a">> => <<"x">>, <<"b">> => <<"y">>, <<"c">> => <<"xy">>},
            binary("a=x,b=${c},c=\"y\", c=${a}${b}")
        ),
        ?_assertEqual(
            #{<<"a">> => <<"x">>, <<"b">> => <<>>, <<"c">> => <<"x">>},
            binary("a=x,b=${c},c=\"\", c=${a}${b}")
        )
    ].

array_element_splice_test_() ->
    [
        ?_assertEqual(#{}, binary(<<>>)),
        ?_assertEqual(#{<<"a">> => []}, binary("a=[]")),
        ?_assertEqual(#{<<"a">> => [<<"xyz">>]}, binary("a=[x y z]")),
        ?_assertEqual(#{<<"a">> => [<<"xyz">>, <<"a">>]}, binary("a=[x y z, a]"))
    ].

expand_paths_test_() ->
    [
        ?_assertEqual(
            #{<<"foo">> => #{<<"x">> => 1}, <<"y">> => 1},
            binary(<<"foo.x=1, y=${foo.x}">>)
        ),
        ?_assertEqual(
            #{<<"foo">> => #{<<"x">> => #{<<"p">> => 1}}, <<"y">> => #{<<"p">> => 1}},
            binary(<<"foo.x={p:1}, y=${foo.x}">>)
        ),
        ?_assertEqual(
            #{<<"foo">> => #{<<"x">> => [1, 2]}, <<"y">> => [1, 2]},
            binary(<<"foo.x=[1,2], y=${foo.x}">>)
        ),
        ?_assertEqual(
            #{<<"foo">> => #{<<"x">> => [1, 2], <<"y">> => [1, 2]}},
            binary(<<"foo.x=[1,2], foo.y=${foo.x}">>)
        ),
        ?_assertEqual(
            #{<<"a">> => #{<<"b">> => #{<<"c">> => 1}}},
            binary(<<"a.b.c={d=1}, a.b.c=${a.b.c.d}">>)
        )
    ].

maybe_var_test_() ->
    [
        ?_assertEqual(#{<<"x">> => 1, <<"y">> => 1}, binary(<<"x=1, y=${?x}">>)),
        ?_assertEqual(#{<<"x">> => 1, <<"y">> => #{}}, binary(<<"x=1, y=${?a}">>)),
        ?_assertEqual(#{<<"x">> => [1, #{}, 3]}, binary(<<"x=[1, ${?x}, 3]">>)),
        ?_assertEqual(#{<<"x">> => <<"aacc">>}, binary(<<"x=aa${?b}cc">>)),
        ?_assertEqual(#{<<"x">> => #{}}, binary(<<"x=${?a}">>)),
        ?_assertEqual(
            #{<<"x">> => #{<<"p">> => 1, <<"q">> => #{}}}, binary(<<"x={p=1, q=${?a}}">>)
        ),
        ?_assertEqual(#{<<"x">> => #{}, <<"z">> => #{}}, binary(<<"x=${?y}, z=${?x}">>)),
        ?_assertEqual(#{<<"x">> => #{<<"p">> => 1}}, binary(<<"x=${?y}{p=1}">>)),
        ?_assertEqual(#{<<"x">> => [1, 2]}, binary(<<"x=${?y}[1, 2]">>)),
        ?_assertEqual(#{<<"x">> => #{<<"p">> => #{}}}, binary(<<"x={p=${?a}}">>)),
        ?_assertEqual(#{<<"x">> => #{}}, binary(<<"x=${?y}${?z}">>))
    ].

cuttlefish_proplists_test_() ->
    [
        ?_assertEqual(
            {ok, [
                {["cluster", "autoclean"], "5m"},
                {["cluster", "autoheal"], "on"},
                {["cluster", "discovery"], "manual"},
                {["cluster", "name"], "emqxcl"},
                {["cluster", "proto_dist"], "inet_tcp"},
                {["node", "cookie"], "emqxsecretcookie"},
                {["node", "data_dir"], "platform_data_dir"},
                {["node", "name"], "emqx@127.0.0.1"}
            ]},
            hocon:load("etc/node.conf", #{format => proplists})
        ),
        ?_assertEqual(
            {ok, [
                {["a"], [1, 2, 3]},
                {["b", "p"], [1, 2, 3]},
                {["c"], [#{<<"p">> => 1}, #{<<"q">> => 1}]},
                {["d"], ["a", "b", "c"]}
            ]},
            hocon:load("etc/proplist-1.conf", #{format => proplists})
        )
    ].

apply_opts_test_() ->
    [
        ?_assertEqual(
            {ok, #{
                <<"GB">> => 1073741824,
                <<"KB">> => 1024,
                <<"MB">> => 1048576,
                <<"day">> => 86400000,
                <<"full">> => 1.0,
                <<"gb">> => 1073741824,
                <<"hour">> => 3600000,
                <<"kb">> => 1024,
                <<"mb">> => 1048576,
                <<"min">> => 60000,
                <<"notkb">> => <<"1kbkb">>,
                <<"off">> => false,
                <<"on">> => true,
                <<"percent">> => 0.01,
                <<"sec">> => 1000,
                <<"x">> => #{<<"kb">> => 1024, <<"sec">> => 1000}
            }},
            hocon:load(
                "etc/convert-sample.conf",
                #{
                    convert => [
                        duration,
                        bytesize,
                        percent,
                        onoff
                    ]
                }
            )
        ),
        ?_assertEqual(
            {ok, #{
                <<"GB">> => ok,
                <<"KB">> => ok,
                <<"MB">> => ok,
                <<"day">> => ok,
                <<"full">> => ok,
                <<"gb">> => ok,
                <<"hour">> => ok,
                <<"kb">> => ok,
                <<"mb">> => ok,
                <<"min">> => ok,
                <<"notkb">> => ok,
                <<"off">> => ok,
                <<"on">> => ok,
                <<"percent">> => ok,
                <<"sec">> => ok,
                <<"x">> => #{<<"kb">> => ok, <<"sec">> => ok}
            }},
            hocon:load(
                "etc/convert-sample.conf",
                #{convert => [fun(_) -> ok end]}
            )
        )
    ].

delete_null_test() ->
    ?assertEqual(
        {ok, #{
            <<"b">> => <<"notnull">>,
            <<"c">> => <<>>,
            <<"d">> => #{<<"x">> => <<"foo">>, <<"y">> => <<"bar">>}
        }},
        hocon:load(
            "etc/null-sample.conf",
            #{delete_null => true}
        )
    ).

required_test() ->
    ?assertEqual({ok, #{}}, hocon:load("etc/optional-include.conf")),
    RequiredRes = hocon:load("etc/required-include.conf"),
    ?assertMatch({error, {enoent, <<"no.conf">>}}, RequiredRes).

include_dirs_test() ->
    Expect =
        #{
            <<"a">> => 1,
            <<"cluster">> =>
                #{
                    <<"autoclean">> => <<"5m">>,
                    <<"autoheal">> => <<"on">>,
                    <<"discovery">> => <<"manual">>,
                    <<"name">> => <<"emqxcl">>,
                    <<"proto_dist">> => <<"inet_tcp">>
                },
            <<"node">> =>
                #{
                    <<"cookie">> => <<"emqxsecretcookie">>,
                    <<"data_dir">> => <<"platform_data_dir">>,
                    <<"name">> => <<"emqx@127.0.0.1">>
                }
        },
    Opts = #{include_dirs => ["test/data", "sample-configs/", "etc/"]},
    Filename = "etc/include-dir.conf",
    {ok, Map} = hocon:load(Filename, Opts),
    ?assertEqual(Expect, Map),
    {ok, Map2} = hocon:binary(hocon_token:read(Filename), Opts),
    ?assertEqual(Expect, Map2),
    {error, Reason} = hocon:load("etc/include-dir-enoent.conf", Opts),
    ?assertEqual({enoent, <<"not-exist.conf">>}, Reason),
    ok.

merge_when_resolve_test() ->
    ?assertEqual(
        {ok, #{
            <<"a">> => #{<<"x">> => 1, <<"y">> => 2},
            <<"b">> => #{<<"x">> => 1, <<"y">> => 2}
        }},
        hocon:binary("a={x:1},a={y:2},b=${a}")
    ),
    ?assertEqual(
        {ok, #{
            <<"a">> => [#{<<"k3">> => 1}, #{<<"k2">> => 2}],
            <<"b">> => [#{<<"k3">> => 1}, #{<<"k2">> => 2}]
        }},
        hocon:binary("a=[{k1=1}] [{k2=2}],a=[{k3=1}] [{k2=2}],b=${a}")
    ).

concat_error_binary_test_() ->
    [
        ?_assertEqual(
            {error, {concat_error, <<"failed_to_concat [{<<\"x\">>,1},[1,2]] at_line 1">>}},
            hocon:binary("a=[1,2], b={x=1}${a}")
        ),
        ?_assertEqual(
            {error, {concat_error, <<"failed_to_concat [<<\"xyz\">>,[1,2]] at_line 1">>}},
            hocon:binary("a=[1,2], b=xyz${a}")
        ),
        ?_assertEqual(
            {error, {concat_error, <<"failed_to_concat [<<\"xyz\">>,2] at_line 1">>}},
            hocon:binary("a=2, b=xyz${a}")
        ),
        ?_assertEqual(
            {error, {concat_error, <<"failed_to_concat [<<\"xyz\">>,2.0] at_line 1">>}},
            hocon:binary("a=2.0, b=xyz${a}")
        ),
        ?_assertEqual(
            {error, {concat_error, <<"failed_to_concat [<<\"xyz\">>,2.0] at_line 2">>}},
            hocon:binary("a=2.0, \nb=xyz${a}")
        ),
        ?_assertEqual(
            {error, {concat_error, <<"failed_to_concat [<<\"xyz\">>,2.0] at_line 2">>}},
            hocon:binary("a=2.0, \nb=\nxyz${a}")
        ),
        ?_assertEqual(
            {error, {concat_error, <<"failed_to_concat [{<<\"x\">>,1},[1,2]] at_line 1">>}},
            hocon:binary("a=[1,2], b={x\n=1}${a}")
        )
    ].

parse_sytax_error_test() ->
    {error, {parse_error, Txt}} = hocon:binary("a=xyz, b=true${a}"),
    ?assertEqual(Txt, <<"syntax error before: <<\"a\">> line_number 1">>).

concat_error_file_test_() ->
    [
        ?_assertEqual(
            [["[[1,2],{<<\"x\">>,1}]", "1", "concat-error-1.conf"]],
            re_error("etc/concat-error-1.conf")
        ),
        ?_assertEqual(
            [["[{<<\"x\">>,1},[1,2]]", "2", "concat-error-2.conf"]],
            re_error("etc/concat-error-2.conf")
        ),
        ?_assertEqual(
            [["[<<\"b\">>,[1]]", "4", "concat-error-3.conf"]],
            re_error("etc/concat-error-3.conf")
        ),
        ?_assertEqual(
            re_error("etc/concat-error-1.conf"),
            re_error("etc/concat-error-4.conf")
        ),
        ?_assertEqual(
            [["[1,<<\"xyz\">>]", "1", "concat-error-5.conf"]],
            re_error("etc/concat-error-5.conf")
        )
    ].

resolve_error_binary_test_() ->
    [
        ?_assertEqual(
            {error, {resolve_error, <<"failed_to_resolve <<\"x\">> at_line 1">>}},
            hocon:binary("a=${x}")
        ),
        ?_assertEqual(
            {error,
                {resolve_error, <<"failed_to_resolve <<\"x\">> at_line 1, <<\"y\">> at_line 2">>}},
            hocon:binary("a=${x}\n ${y}")
        ),
        ?_assertEqual(
            {ok, #{<<"a">> => #{}, <<"x">> => #{}}},
            hocon:binary("a=${x}\n x=${?y}")
        )
    ].

resolve_error_file_test_() ->
    [
        ?_assertEqual(
            [
                ["<<\"x\">>", "2", "resolve-error-1.conf"],
                ["<<\"y\">>", "2", "resolve-error-1.conf"],
                ["<<\"y\">>", "4", "resolve-error-1.conf"]
            ],
            re_error("etc/resolve-error-1.conf")
        ),
        ?_assertEqual(
            lists:append(
                re_error("etc/resolve-error-1.conf"),
                re_error("etc/resolve-error-1.conf")
            ),
            re_error("etc/resolve-error-2.conf")
        )
    ].

duration_test_() ->
    [
        ?_assertEqual(1, hocon_postprocess:duration("1ms")),
        ?_assertEqual(1000, hocon_postprocess:duration("1s")),
        ?_assertEqual(20000, hocon_postprocess:duration("20s")),
        ?_assertEqual(60000, hocon_postprocess:duration("1m")),
        ?_assertEqual(86400000, hocon_postprocess:duration("1d")),
        ?_assertEqual(604800000, hocon_postprocess:duration("1w")),
        ?_assertEqual(1209600000, hocon_postprocess:duration("1f")),
        ?_assertEqual("10sss", hocon_postprocess:duration("10sss")),
        ?_assertEqual(61000, hocon_postprocess:duration("1m1s")),
        ?_assertEqual("1m1ss", hocon_postprocess:duration("1m1ss")),
        ?_assertEqual(1000, hocon_postprocess:duration("1S")),
        ?_assertEqual(61001, hocon_postprocess:duration("1m1S1ms")),
        ?_assertEqual(true, hocon_postprocess:duration(true)),
        ?_assertEqual(30000, hocon_postprocess:duration(".5m")),
        ?_assertEqual(1599, hocon_postprocess:duration("1.599s")),
        ?_assertEqual(1600, hocon_postprocess:duration("1.6s")),
        ?_assertEqual(6100, hocon_postprocess:duration(".1m.1s")),
        ?_assertEqual(6100, hocon_postprocess:duration(".1m0.1s")),
        ?_assertEqual(6100, hocon_postprocess:duration("0.1m0.1s"))
    ].

richmap_binary_test() ->
    {ok, M0} = hocon:binary("a=1", #{format => richmap}),
    ?assertEqual(
        #{
            ?METADATA => #{line => 0},
            ?HOCON_T => object,
            ?HOCON_V =>
                #{
                    <<"a">> =>
                        #{
                            ?METADATA => #{line => 1},
                            ?HOCON_T => integer,
                            ?HOCON_V => 1
                        }
                }
        },
        M0
    ),
    {ok, M1} = hocon:binary("a=[1,2]", #{format => richmap}),
    ?assertEqual(
        #{
            ?METADATA => #{line => 0},
            ?HOCON_T => object,
            ?HOCON_V =>
                #{
                    <<"a">> =>
                        #{
                            ?METADATA => #{line => 1},
                            ?HOCON_T => array,
                            ?HOCON_V =>
                                [
                                    #{
                                        ?METADATA =>
                                            #{line => 1},
                                        ?HOCON_T => integer,
                                        ?HOCON_V => 1
                                    },
                                    #{
                                        ?METADATA =>
                                            #{line => 1},
                                        ?HOCON_T => integer,
                                        ?HOCON_V => 2
                                    }
                                ]
                        }
                }
        },
        M1
    ),
    {ok, M2} = hocon:binary("a\n{b=foo}", #{format => richmap}),
    ?assertEqual(
        #{
            ?METADATA => #{line => 0},
            ?HOCON_T => object,
            ?HOCON_V =>
                #{
                    <<"a">> =>
                        #{
                            ?METADATA => #{line => 1},
                            ?HOCON_T => object,
                            ?HOCON_V =>
                                #{
                                    <<"b">> =>
                                        #{
                                            ?METADATA =>
                                                #{line => 2},
                                            ?HOCON_T => string,
                                            ?HOCON_V => <<"foo">>
                                        }
                                }
                        }
                }
        },
        M2
    ).

richmap_file_test() ->
    {ok, Map} = hocon:load("etc/node.conf", #{format => richmap}),
    #{
        ?HOCON_V :=
            #{
                <<"cluster">> :=
                    #{
                        ?HOCON_V :=
                            #{
                                <<"autoclean">> :=
                                    #{
                                        ?METADATA := #{filename := F, line := 7},
                                        ?HOCON_V := <<"5m">>
                                    }
                            }
                    }
            }
    } = Map,
    ?assertEqual("node.conf", filename:basename(F)).

files_test() ->
    Filename = fun(Metadata) -> filename:basename(maps:get(filename, Metadata)) end,
    {ok, Conf} = hocon:files(
        ["sample-configs/a_1.conf", "sample-configs/b_2.conf"],
        #{format => richmap}
    ),
    ?assertEqual(1, deep_get("a", Conf, ?HOCON_V)),
    ?assertEqual("a_1.conf", Filename(deep_get("a", Conf, ?METADATA))),
    ?assertEqual(2, deep_get("b", Conf, ?HOCON_V)),
    ?assertEqual("b_2.conf", Filename(deep_get("b", Conf, ?METADATA))).

files_esc_test() ->
    Content = "backslash = gotcha\n",
    SpecialFile = "test/data/a\\b.conf",
    ok = file:write_file(SpecialFile, Content),
    try
        Filename = fun(Metadata) -> filename:basename(maps:get(filename, Metadata)) end,
        {ok, Conf} = hocon:files(
            ['sample-configs/a_1.conf', <<"sample-configs/b_2.conf">>, SpecialFile],
            #{format => richmap}
        ),
        ?assertEqual(1, deep_get("a", Conf, ?HOCON_V)),
        ?assertEqual("a_1.conf", Filename(deep_get("a", Conf, ?METADATA))),
        ?assertEqual(2, deep_get("b", Conf, ?HOCON_V)),
        ?assertEqual("b_2.conf", Filename(deep_get("b", Conf, ?METADATA))),
        ?assertEqual(<<"gotcha">>, deep_get("backslash", Conf, ?HOCON_V))
    after
        file:delete(SpecialFile)
    end.

files_unicode_path_test() ->
    Content =
        <<
            "a=1\n"
            "b=2\n"
            "unicode = \"测试unicode文件路径\"\n"
            "\"语言.英文\" = english\n"/utf8
        >>,
    Filename =
        case file:native_name_encoding() of
            latin1 -> <<"a\"filen\tame">>;
            utf8 -> <<"文件\"名\ta"/utf8>>
        end,
    ok = file:write_file(Filename, Content),
    try
        {ok, Conf} = hocon:files(
            [Filename],
            #{format => richmap}
        ),
        ?assertEqual(<<"测试unicode文件路径"/utf8>>, deep_get("unicode", Conf, ?HOCON_V)),
        ?assertEqual(<<"english">>, deep_get("语言.英文", Conf, ?HOCON_V))
    after
        file:delete(Filename)
    end.

deep_get(Key, Conf, Tag) ->
    Map = hocon_maps:deep_get(Key, Conf),
    maps:get(Tag, Map).

utf8_test() ->
    %todo support unicode
    ?assertMatch({error, {scan_error, _}}, hocon:load("etc/utf8.conf")).

re_error(Filename0) ->
    {error, {_ErrorType, Msg}} = hocon:load(Filename0),
    {ok, MP} = re:compile("([^ \(\t\n\r\f]+) at_line ([0-9]+) in_file ([^ \t\n\r\f,]+)"),
    {match, VLFs} = re:run(
        Msg,
        MP,
        [global, {capture, all_but_first, list}]
    ),
    lists:map(fun([V, L, F]) -> [V, L, filename:basename(F)] end, VLFs).

binary(B) when is_binary(B) ->
    {ok, R} = hocon:binary(B),
    R;
binary(IO) ->
    binary(iolist_to_binary(IO)).

array_mrege_test_() ->
    Parse = fun(Input) ->
        {ok, RichRes} = hocon:binary(Input, #{format => richmap}),
        {ok, Res} = hocon:binary(Input, #{format => map}),
        ?assertEqual(Res, hocon_util:richmap_to_map(RichRes)),
        Res
    end,
    [
        {"empty_base", ?_assertEqual(#{<<"a">> => [42]}, Parse("a=[], a.1=42"))},
        {"override_1", ?_assertEqual(#{<<"a">> => [42]}, Parse("a=[1], a.1=42"))},
        {"override_2",
            ?_assertEqual(
                #{<<"a">> => [42, 43]},
                Parse("a=[1], a:{\"1\":42,\"2\":43}")
            )},
        {"append_1", ?_assertEqual(#{<<"a">> => [1, 42]}, Parse("a=[1], a.2=42"))},
        {"no_array_convert",
            ?_assertEqual(
                #{<<"a">> => #{<<"1">> => 42}},
                Parse("a=one, a.1=42")
            )},
        {"empty_base_nested",
            ?_assertEqual(#{<<"a">> => [#{<<"b">> => 1}]}, Parse("a=[], a.1.b=1"))},
        {"empty_base_nested_overrite",
            ?_assertEqual(#{<<"a">> => [#{<<"b">> => 1}]}, Parse("a=[x], a.1.b=1"))},
        {"override_10_elements_test",
            ?_assertEqual(
                #{
                    <<"a">> => [
                        #{<<"b">> => 1},
                        #{<<"b">> => 2},
                        #{<<"b">> => 3},
                        #{<<"b">> => 4},
                        #{<<"b">> => 5},
                        #{<<"b">> => 6},
                        #{<<"b">> => 7},
                        #{<<"b">> => 8},
                        #{<<"b">> => 9},
                        #{<<"b">> => 10}
                    ]
                },
                Parse(
                    "a=[x],"
                    "a.1.b=1, a.2.b=2, a.3.b=3,"
                    "a.4.b=4, a.5.b=5, a.6.b=6,a.7.b=7, a.8.b=8, a.9.b=9"
                    "a.10.b=10"
                )
            )},
        {"array_of_arrays",
            ?_assertEqual(
                #{<<"a">> => [[1, 2], [3, 4]]},
                Parse("a=[[],[]], a.1.1=1, a.1.2=2, a.2.1=3, a.2.2=4")
            )},
        {"array_of_arrays_2",
            ?_assertEqual(
                #{<<"a">> => [[1, 2], #{<<"1">> => 3, <<"2">> => 4}]},
                Parse("a=[[]], a.1.1=1, a.1.2=2, a.2.1=3, a.2.2=4")
            )},
        {"array_override_by_obj",
            ?_assertEqual(#{<<"a">> => #{<<"b">> => 1}}, Parse("a=[1, 2,], a.b=1"))}
    ].

unescape_test() ->
    {ok, Conf} = hocon:load("./test/data/unescape.conf"),
    ?assertEqual(
        #{
            <<"a">> => <<"a\nb">>,
            <<"c">> => <<"e\"f">>,
            <<"d">> => <<"x\ty">>,
            <<"e">> => <<"x\\ty">>
        },
        Conf
    ).

unicode_utf8_test() ->
    {ok, Conf} = hocon:load("./test/data/unicode-utf8.conf"),
    ?assertEqual(
        #{
            <<"test">> =>
                #{
                    <<"body">> => <<"<!-- Edited by XML-XXX® --><note>\n</note>"/utf8>>,
                    <<"text">> => <<"你我他"/utf8>>
                }
        },
        Conf
    ).

invalid_utf8_test() ->
    ?assertMatch(
        {error, {scan_invalid_utf8, _, _}},
        hocon:load("./test/data/invalid-utf8.conf")
    ).
