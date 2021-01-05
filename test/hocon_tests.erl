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

test_file_load("cycle"++_, F) ->
    ?assertMatch({error, {cycle, _}}, hocon:load(F));
test_file_load("test13-reference-bad-substitutions", F) ->
    ?assertMatch({error, {{unresolved,[b]}, _}}, hocon:load(F));
% include "test01" is not allowed.
test_file_load("test03", F) ->
    ?assertMatch({error,{enoent,_Filename}}, hocon:load(F));
test_file_load("test03-included", F) ->
    ?assertMatch({error, {{unresolved,[bar]}, _}}, hocon:load(F));
test_file_load("test05", F) ->
    ?assertMatch({error,{scan_error,"illegal characters \"%\" in line 15"}}, hocon:load(F));
test_file_load("test07", F) ->
    ?assertMatch({error, {enoent, _Filename}}, hocon:load(F));
test_file_load("test08", F) ->
    ?assertMatch({error, {enoent, _Filename}}, hocon:load(F));
test_file_load("test10", F) ->
    ?assertEqual({ok,#{bar =>
                       #{nested =>
                         #{a => #{c => 3,q => 10},
                           b => 5,
                           c =>
                           #{d => 600,
                             e => #{c => 3},
                             f => 5,q => 10},
                           x => #{q => 10},
                           y => 5}},
                       foo =>
                       #{a => #{c => 3,q => 10},
                         b => 5,
                         c => #{d => 600,e => #{c => 3},f => 5,q => 10},
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
    [ ?_assertEqual(#{a => [1,2,3,4]}, binary("a=[1, 2] [3, 4]"))
    , ?_assertEqual(#{a => [1,2,3,4]}, binary("a=[1, 2][3, 4]"))
    , ?_assertEqual(#{a => [1,2,3,4]}, binary("a=[1, 2,][3, 4]"))
    , ?_assertEqual(#{a => [1,2,3,4]}, binary("a=[1, 2, ][3, 4]"))
    , ?_assertEqual(#{a => [1,2,3,4]}, binary("a=[1, 2, \n][3, 4]"))
    , ?_assertEqual(#{x => [1,2],y => [1,2,1,2]}, binary("x=[1,2],y=${x}[1,2]"))
    , ?_assertEqual(#{x => [1,2],y => [[1,2],[1,2]]}, binary("x=[1,2],y=[${x},[1,2]]"))
    , ?_assertEqual(#{a => #{x => [1,2,<<"str">>,#{a => 1}]}}, binary("a={x=[1,2,str][{a=1}]}"))
    , ?_assertEqual(#{z => [#{a => 1, b => 1}, #{c => 1}]}, binary("z=[{a=1}{b=1}, {c=1}]"))
    , ?_assertEqual(#{x => #{a => 1, b => 1}}, binary("x={a=1} {b=${x.a}}"))
    , ?_assertEqual(#{x => #{a => 1, b => 1}}, binary("x={a=${x.b}} {b=1}"))
    , ?_assertEqual(#{x => #{a => 1, b => 1}}, binary("x={a=${x.b} b=1}"))
    , ?_assertEqual(#{x => #{a => #{p => 1, q => 1}, b => 1}}, binary("x={a={p=${x.a.q}, q=${x.b}} b=1}"))
    ].

object_concat_test_() ->
    [ ?_assertEqual(#{a => #{b => 1,c => 2}}, binary("a={b=1} {c=2}"))
    , ?_assertEqual(#{a => #{b => 1,c => 2}}, binary("a={b=1}{c=2}"))
    , ?_assertEqual(#{a => #{b => 1,c => 2}}, binary("a={b=1,}{c=2}"))
    , ?_assertEqual(#{a => #{b => 1,c => 2},x => #{c => 2}}, binary("x={c=2},a={b=1,}${x}"))
    , ?_assertEqual(#{a => #{b => 1,c => 2},x => #{c => 2}}, binary("x={c=2},a={b=1, }${x}"))
    , ?_assertEqual(#{a => #{b => 1,c => 2},x => #{c => 2}}, binary("x={c=2},a={b=1,\n}${x}"))
    , ?_assertEqual(#{a => #{x => 1,y => 2},b => #{x => 1,y => 2,z => 0}}, binary("a={x=1,y=2},b={x=0,y=0,z=0}${a}"))
    , ?_assertEqual(#{a => #{x => 1,y => 2},b => #{x => 0,y => 0,z => 0}}, binary("a={x=1,y=2},b=${a}{x=0,y=0,z=0}"))
    , ?_assertEqual(#{a => #{x => [1,2,#{a => 1}]}}, binary("a={x=[1,2,{a:1}]}"))
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
    [ ?_assertEqual(#{a => <<"x">>,b => <<"y">>,c => <<"xy">>}, binary("a=x,b=${c},c=\"y\", c=${a}${b}"))
    , ?_assertEqual(#{a => <<"x">>,b => <<>>,c => <<"x">>}, binary("a=x,b=${c},c=\"\", c=${a}${b}"))
    ].

array_element_splice_test_() ->
    [ ?_assertEqual(#{}, binary(<<>>))
    , ?_assertEqual(#{a=>[]}, binary("a=[]"))
    , ?_assertEqual(#{a=>[<<"xyz">>]}, binary("a=[x y z]"))
    , ?_assertEqual(#{a=>[<<"xyz">>,<<"a">>]}, binary("a=[x y z, a]"))
    ].

binary(B) when is_binary(B) ->
    {ok, R} = hocon:binary(B),
    R;
binary(IO) -> binary(iolist_to_binary(IO)).
