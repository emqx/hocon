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

-module(hocon_tests).

-include_lib("eunit/include/eunit.hrl").

%% try to load all sample files
%% expect no crash
sample_files_test_() ->
    Wildcard = filename:join([code:lib_dir(hocon), "sample-configs", "*.conf"]),
    [begin
        BaseName = filename:basename(F, ".conf"),
        Json = filename:join([code:lib_dir(hocon),
                              "sample-configs", "json", BaseName ++ ".conf.json"]),
        {BaseName, fun() -> test_interop(BaseName, F, Json), test_file_load(BaseName, F) end}
     end || F <- filelib:wildcard(Wildcard)].
%% include file() is not supported.
test_file_load("file-include", F) ->
    ?assertMatch({error, {scan_error, _}}, hocon:load(F));
%% unquoted string starting by null is not allowed.
test_file_load("test01", F) ->
    ?assertError(_, hocon:load(F));
%% includes test01
test_file_load("include-from-list", F) ->
    ?assertError(_, hocon:load(F));
%% do not allow quoted variable name.
test_file_load("test02"++_, F) ->
    ?assertMatch({error, {scan_error, _}}, hocon:load(F));
test_file_load("cycle"++_, F) ->
    ?assertMatch({error, {cycle, _}}, hocon:load(F));
test_file_load("test13-reference-bad-substitutions", F) ->
    ?assertMatch([["b", "test13-reference-bad-substitutions.conf", "1"]], re_error(F));
% include "test01" is not allowed.
test_file_load("test03", F) ->
    ?assertMatch({error, {scan_error, _}}, hocon:load(F));
test_file_load("test03-included", F) ->
    ?assertMatch([["bar", "test03-included.conf", "9"]], re_error(F));
test_file_load("test05", F) ->
    ?assertMatch({error, {scan_error, _}}, hocon:load(F));
test_file_load("test07", F) ->
    ?assertMatch({ok, #{}}, hocon:load(F));
test_file_load("test08", F) ->
    ?assertMatch({ok, #{}}, hocon:load(F));
test_file_load("test10", F) ->
    ?assertEqual({ok, #{bar =>
                        #{nested =>
                          #{a => #{c => 3, q => 10},
                            b => 5,
                            c =>
                            #{d => 600,
                              e => #{c => 3, q => 10},
                              f => 5, q => 10},
                            x => #{q => 10},
                            y => 5}},
                        foo =>
                        #{a => #{c => 3, q => 10},
                          b => 5,
                          c => #{d => 600, e => #{c => 3, q => 10}, f => 5, q => 10},
                          x => #{q => 10},
                          y => 5}}},
                 hocon:load(F));
test_file_load(_Name, F) ->
    ?assertMatch({ok, _}, hocon:load(F)).

% hoc2js converts 8.0 to 8
test_interop("test04", Conf, Json) ->
    case hocon:load(Conf) of
        {error, _} ->
            ok;
        {ok, Res} ->
            IntRes = hocon_util:do_deep_merge(Res, #{akka =>
                                                     #{actor =>
                                                       #{'default-dispatcher' =>
                                                         #{'core-pool-size-factor' => 8,
                                                           'max-pool-size-factor' => 8 }}}}),
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

commas_test_() ->
    [ ?_assertEqual(binary("a=[1,2,3]"), binary("a=[1,2,3,]"))
    , ?_assertEqual(binary("a=[1,2,3]"), binary("a=[1\n2\n3]"))
    , ?_assertError(_, binary("a=[1,2,3,,]"))
    , ?_assertError(_, binary("a=[,1,2,3]"))
    , ?_assertError(_, binary("a=[1,,2,3]"))
    , ?_assertEqual(binary("a={b=1, c=2}"), binary("a={b=1, c=2,}"))
    , ?_assertEqual(binary("a={b=1, c=2}"), binary("a={b=1\nc=2}"))
    , ?_assertError(_, binary("a={b=1,c=2,,}"))
    , ?_assertError(_, binary("a={,b=1,c=2}"))
    , ?_assertError(_, binary("a={b=1,,c=2}"))
    ].

object_merging_test_() ->
    [ ?_assertEqual(binary("a={b=1, c=2}"), binary("a={b=1}, a={c=2}"))
    , ?_assertEqual(binary("a={b=1, c=2}"), binary("a={b=1, c=1}, a={c=2}"))
    , ?_assertEqual(binary("a={c=2}"), binary("a={b=1, c=1}, a=a, a={c=2}"))
    ].

unquoted_test_() ->
    [ ?_assertEqual(#{a => true}, binary("a=true"))
    , ?_assertEqual(#{a => false}, binary("a=false"))
    , ?_assertEqual(#{a => null}, binary("a=null"))
    ].

multiline_string_test_() ->
    [].

array_concat_test_() ->
    [ ?_assertEqual(#{a => [1, 2, 3, 4]}, binary("a=[1, 2] [3, 4]"))
    , ?_assertEqual(#{a => [1, 2, 3, 4]}, binary("a=[1, 2][3, 4]"))
    , ?_assertEqual(#{a => [1, 2, 3, 4]}, binary("a=[1, 2,][3, 4]"))
    , ?_assertEqual(#{a => [1, 2, 3, 4]}, binary("a=[1, 2, ][3, 4]"))
    , ?_assertEqual(#{a => [1, 2, 3, 4]}, binary("a=[1, 2, \n][3, 4]"))
    , ?_assertEqual(#{x => [1, 2], y => [1, 2, 1, 2]}, binary("x=[1,2],y=${x}[1,2]"))
    , ?_assertEqual(#{x => [1, 2], y => [[1, 2], [1, 2]]}, binary("x=[1,2],y=[${x},[1,2]]"))
    , ?_assertEqual(#{a => #{x => [1, 2, <<"str">>, #{a => 1}]}}, binary("a={x=[1,2,str][{a=1}]}"))
    , ?_assertEqual(#{z => [#{a => 1, b => 1}, #{c => 1}]}, binary("z=[{a=1}{b=1}, {c=1}]"))
    , ?_assertEqual(#{x => #{a => 1, b => 1}}, binary("x={a=1} {b=${x.a}}"))
    , ?_assertEqual(#{x => #{a => 1, b => 1}}, binary("x={a=${x.b}} {b=1}"))
    , ?_assertEqual(#{x => #{a => 1, b => 1}}, binary("x={a=${x.b} b=1}"))
    , ?_assertEqual(#{x => #{a => #{p => 1, q => 1}, b => 1}},
                    binary("x={a={p=${x.a.q}, q=${x.b}} b=1}"))
    ].

object_concat_test_() ->
    [ ?_assertEqual(#{a => #{b => 1, c => 2}}, binary("a={b=1} {c=2}"))
    , ?_assertEqual(#{a => #{b => 1, c => 2}}, binary("a={b=1}{c=2}"))
    , ?_assertEqual(#{a => #{b => 1, c => 2}}, binary("a={b=1,}{c=2}"))
    , ?_assertEqual(#{a => #{b => 1, c => 2}, x => #{c => 2}},
                    binary("x={c=2},a={b=1,}${x}"))
    , ?_assertEqual(#{a => #{b => 1, c => 2}, x => #{c => 2}},
                    binary("x={c=2},a={b=1, }${x}"))
    , ?_assertEqual(#{a => #{b => 1, c => 2}, x => #{c => 2}},
                    binary("x={c=2},a={b=1,\n}${x}"))
    , ?_assertEqual(#{a => #{x => 1, y => 2}, b => #{x => 1, y => 2, z => 0}},
                    binary("a={x=1,y=2},b={x=0,y=0,z=0}${a}"))
    , ?_assertEqual(#{a => #{x => 1, y => 2}, b => #{x => 0, y => 0, z => 0}},
                    binary("a={x=1,y=2},b=${a}{x=0,y=0,z=0}"))
    , ?_assertEqual(#{a => #{x => [1, 2, #{a => 1}]}}, binary("a={x=[1,2,{a:1}]}"))
    ].


string_concat_test_() ->
    [ ?_assertEqual(#{a => <<"foobar">>}, binary("a=foo\"bar\""))
    , ?_assertEqual(#{a => <<"foobar">>, x => <<"foo">>}, binary("x=foo,a=${x}bar"))
    ].

float_point_test_() ->
    [ ?_assertEqual(#{a => 0.5}, binary("a=0.5"))
    , ?_assertEqual(#{a => 0.5}, binary("a=.5"))
    , ?_assertEqual(#{a => 1.5}, binary("a=1.5"))
    ].

look_forward_test_() ->
    [ ?_assertEqual(#{a => <<"x">>, b => <<"y">>, c => <<"xy">>},
                    binary("a=x,b=${c},c=\"y\", c=${a}${b}"))
    , ?_assertEqual(#{a => <<"x">>, b => <<>>, c => <<"x">>},
                    binary("a=x,b=${c},c=\"\", c=${a}${b}"))
    ].

array_element_splice_test_() ->
    [ ?_assertEqual(#{}, binary(<<>>))
    , ?_assertEqual(#{a=>[]}, binary("a=[]"))
    , ?_assertEqual(#{a=>[<<"xyz">>]}, binary("a=[x y z]"))
    , ?_assertEqual(#{a=>[<<"xyz">>, <<"a">>]}, binary("a=[x y z, a]"))
    ].

expand_paths_test_() ->
    [ ?_assertEqual(#{foo => #{x => 1}, y => 1},
                    binary(<<"foo.x=1, y=${foo.x}">>))
    , ?_assertEqual(#{foo => #{x => #{p => 1}}, y => #{p => 1}},
                    binary(<<"foo.x={p:1}, y=${foo.x}">>))
    , ?_assertEqual(#{foo => #{x => [1, 2]}, y => [1, 2]},
                    binary(<<"foo.x=[1,2], y=${foo.x}">>))
    , ?_assertEqual(#{foo => #{x => [1, 2], y => [1, 2]}},
                    binary(<<"foo.x=[1,2], foo.y=${foo.x}">>))
    , ?_assertEqual(#{a => #{b => #{c => 1}}},
                    binary(<<"a.b.c={d=1}, a.b.c=${a.b.c.d}">>))
    ].

maybe_var_test_() ->
    [ ?_assertEqual(#{x => 1, y => 1}, binary(<<"x=1, y=${?x}">>))
    , ?_assertEqual(#{x => 1}, binary(<<"x=1, y=${?a}">>))
    , ?_assertEqual(#{x => [1, 3]}, binary(<<"x=[1, ${?x}, 3]">>))
    , ?_assertEqual(#{x => <<"aacc">>}, binary(<<"x=aa${?b}cc">>))
    , ?_assertEqual(#{}, binary(<<"x=${?a}">>))
    , ?_assertEqual(#{x => #{p => 1}}, binary(<<"x={p=1, q=${?a}}">>))
    , ?_assertEqual(#{}, binary(<<"x=${?y}, z=${?x}">>))
    , ?_assertEqual(#{x => #{p => 1}}, binary(<<"x=${?y}{p=1}">>))
    , ?_assertEqual(#{x => [1, 2]}, binary(<<"x=${?y}[1, 2]">>))
    , ?_assertEqual(#{x => #{}}, binary(<<"x={p=${?a}}">>))
    , ?_assertEqual(#{}, binary(<<"x=${?y}${?z}">>))
    ].

cuttlefish_proplists_test() ->
    ?assertEqual({ok, [{["node", "name"], "emqx@127.0.0.1"},
                       {["node", "data_dir"], "platform_data_dir"},
                       {["node", "cookie"], "emqxsecretcookie"},
                       {["cluster", "proto_dist"], "inet_tcp"},
                       {["cluster", "name"], "emqxcl"},
                       {["cluster", "discovery"], "manual"},
                       {["cluster", "autoheal"], "on"},
                       {["cluster", "autoclean"], "5m"}]},
                 hocon:load("etc/node.conf", #{format => proplists})).

apply_opts_test() ->
    ?assertEqual({ok, #{day => 86400000, full => 1.0, gb => 1073741824,
                        hour => 3600000, kb => 1024, mb => 1048576, min => 60000,
                        off => false, on => true, percent => 0.01, sec => 1000,
                        x => #{kb => 1024, sec => 1000}}},
                 hocon:load("etc/convert-sample.conf",
                            #{convert => [duration,
                                          bytesize,
                                          percent,
                                          onoff]})),
    MyFun = fun (_) -> ok end,
    ?assertEqual({ok, #{day => ok, full => ok, gb => ok, hour => ok, kb => ok,
                        mb => ok, min => ok, off => ok, on => ok, percent => ok,
                        sec => ok,
                        x => #{kb => ok, sec => ok}}},
                 hocon:load("etc/convert-sample.conf",
                            #{convert => [MyFun]})).

delete_null_test() ->
    ?assertEqual({ok, #{b => <<"notnull">>, c => <<>>,
                        d => #{x => <<"foo">>, y => <<"bar">>}}},
                 hocon:load("etc/null-sample.conf",
                                #{delete_null => true})).

required_test() ->
    ?assertEqual({ok, #{}}, hocon:load("etc/optional-include.conf")),
    ?assertMatch({error, {enoent, _}}, hocon:load("etc/required-include.conf")).

merge_when_resolve_test() ->
    ?assertEqual({ok, #{a => #{x => 1, y => 2}, b => #{x => 1, y => 2}}},
                 hocon:binary("a={x:1},a={y:2},b=${a}")),
    ?assertEqual({ok, #{a => [#{k3 => 1}, #{k2 => 2}],
                        b => [#{k3 => 1}, #{k2 => 2}]}},
                 hocon:binary("a=[{k1=1}] [{k2=2}],a=[{k3=1}] [{k2=2}],b=${a}")).

concat_error_binary_test_() ->
    [ ?_assertEqual({error,
                     {concat_error,
                      <<"failed_to_concat [{x,1},[1,2]] at_line 1">>}},
                    hocon:binary("a=[1,2], b={x=1}${a}"))
    , ?_assertEqual({error,
                     {concat_error,
                      <<"failed_to_concat [<<\"xyz\">>,[1,2]] at_line 1">>}},
                    hocon:binary("a=[1,2], b=xyz${a}"))
    , ?_assertEqual({error,
                     {concat_error,
                      <<"failed_to_concat [<<\"xyz\">>,2] at_line 1">>}},
                    hocon:binary("a=2, b=xyz${a}"))
    , ?_assertEqual({error,
                     {concat_error,
                      <<"failed_to_concat [<<\"xyz\">>,2.0] at_line 1">>}},
                    hocon:binary("a=2.0, b=xyz${a}"))
    , ?_assertEqual({error,
                     {parse_error,
                      <<"syntax error before: a at_line 1.">>}},
                    hocon:binary("a=xyz, b=true${a}"))
    , ?_assertEqual({error,
                     {concat_error,
                      <<"failed_to_concat [<<\"xyz\">>,2.0] at_line 2">>}},
                    hocon:binary("a=2.0, \nb=xyz${a}"))
    , ?_assertEqual({error,
                     {concat_error,
                      <<"failed_to_concat [<<\"xyz\">>,2.0] at_line 2">>}},
                    hocon:binary("a=2.0, \nb=\nxyz${a}"))
    , ?_assertEqual({error,
                     {concat_error,
                      <<"failed_to_concat [{x,1},[1,2]] at_line 1">>}},
                    hocon:binary("a=[1,2], b={x\n=1}${a}"))
    ].

concat_error_file_test_() ->
    [ ?_assertEqual([["[[1,2],{x,1}]", "concat-error-1.conf", "1"]],
                    re_error("etc/concat-error-1.conf"))
    , ?_assertEqual([["[{x,1},[1,2]]", "concat-error-2.conf", "2"]],
                    re_error("etc/concat-error-2.conf"))
    , ?_assertEqual([["[<<\"b\">>,[1]]", "concat-error-3.conf", "4"]],
                    re_error("etc/concat-error-3.conf"))
    , ?_assertEqual(re_error("etc/concat-error-1.conf"),
                    re_error("etc/concat-error-4.conf"))
    , ?_assertEqual([["[1,<<\"xyz\">>]", "concat-error-5.conf", "1"]],
                    re_error("etc/concat-error-5.conf"))
    ].

resolve_error_file_test_() ->
    [ ?_assertEqual([["x", "resolve-error-1.conf", "2"],
                     ["y", "resolve-error-1.conf", "2"],
                     ["y", "resolve-error-1.conf", "4"]], re_error("etc/resolve-error-1.conf"))
    , ?_assertEqual(lists:append(re_error("etc/resolve-error-1.conf"),
                                 re_error("etc/resolve-error-1.conf")),
                    re_error("etc/resolve-error-2.conf"))
    ].

re_error(Filename0) ->
    {error, {_ErrorType, Msg}} = hocon:load(Filename0),
    {ok, MP} = re:compile("([^ \(\t\n\r\f]+) in_file \"([^ \t\n\r\f]+)\" at_line ([0-9]+)"),
    {match, VFLs} = re:run(binary_to_list(Msg), MP,
                           [global, {capture, all_but_first, list}]),
    lists:map(fun ([V, F, L]) -> [V, filename:basename(F), L] end, VFLs).

binary(B) when is_binary(B) ->
    {ok, R} = hocon:binary(B),
    R;
binary(IO) -> binary(iolist_to_binary(IO)).
