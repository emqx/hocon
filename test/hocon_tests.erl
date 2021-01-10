%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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
        {BaseName, fun() -> test_file_load(BaseName, F) end}
     end || F <- filelib:wildcard(Wildcard)].
%% include file() is not supported.
test_file_load("file-include", F) ->
    ?assertMatch({error, {scan_error, _}}, hocon:load(F));
%% unquoted string starting by null is not allowed.
%% Failure/Error: {error,function_clause,
%%                        [{io_lib,write_string1,
%%                             [unicode_as_unicode,<<"bar">>,34],
%%                             [{file,"io_lib.erl"},{line,581}]},
%%                         {io_lib,write_string,2,
%%                             [{file,"io_lib.erl"},{line,553}]},
%%                         {hocon_parser,yeccerror,1, ...
test_file_load("test01", F) ->
    ?assertError(_, hocon:load(F));
%% do not allow quoted variable name.
test_file_load("test02"++_, F) ->
    ?assertMatch({error, {scan_error, _}}, hocon:load(F));
test_file_load("cycle"++_, F) ->
    ?assertMatch({error, {cycle, _}}, hocon:load(F));
test_file_load("test13-reference-bad-substitutions", F) ->
    ?assertMatch({error, {unresolved, [b]}}, hocon:load(F));
% include "test01" is not allowed.
test_file_load("test03", F) ->
    ?assertMatch({error, {enoent, _}}, hocon:load(F));
test_file_load("test03-included", F) ->
    ?assertMatch({error, {unresolved, [bar]}}, hocon:load(F));
test_file_load("test05", F) ->
    ?assertMatch({error, {scan_error, "illegal characters \"%\" in line 15"}}, hocon:load(F));
test_file_load("test07", F) ->
    ?assertMatch({error, {enoent, _}}, hocon:load(F));
test_file_load("test08", F) ->
    ?assertMatch({error, {enoent, _}}, hocon:load(F));
test_file_load("test10", F) ->
    ?assertEqual({ok, #{bar =>
                        #{nested =>
                          #{a => #{c => 3, q => 10},
                            b => 5,
                            c =>
                            #{d => 600,
                              e => #{c => 3},
                              f => 5, q => 10},
                            x => #{q => 10},
                            y => 5}},
                        foo =>
                        #{a => #{c => 3, q => 10},
                          b => 5,
                          c => #{d => 600, e => #{c => 3}, f => 5, q => 10},
                          x => #{q => 10},
                          y => 5}}},
                 hocon:load(F));
test_file_load(_Name, F) ->
    ?assertMatch({ok, _}, hocon:load(F)).

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

cuttlefish_proplist_test() ->
    Schema = filename:absname("priv/emqx_auth_redis.schema"),
    {ok, Proplist} = hocon:load("etc/emqx_auth_redis.conf", [{format, proplist}]),
    ?assertEqual([{emqx_auth_redis,
                   [{acl_cmd, "HGETALL mqtt_acl:%u"},
                    {super_cmd, "HGET mqtt_user:%u is_superuser"},
                    {auth_cmd, "HMGET mqtt_user:%u password"},
                    {options, [{options, []}]},
                    {server,
                     [{type, single},
                      {pool_size, 8},
                      {auto_reconnect, 1},
                      {database, 0},
                      {password, []},
                      {sentinel, []},
                      {host, "127.0.0.1"},
                      {port, 6379}]},
                    {query_timeout, infinity},
                    {password_hash, plain}]}],
                 cuttlefish_generator:map(cuttlefish_schema:files([Schema]), Proplist)).

binary(B) when is_binary(B) ->
    {ok, R} = hocon:binary(B),
    R;
binary(IO) -> binary(iolist_to_binary(IO)).
