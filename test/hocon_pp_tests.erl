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
-module(hocon_pp_tests).

-include_lib("erlymatch/include/erlymatch.hrl").
-include_lib("typerefl/include/types.hrl").

pp_test_() ->
    [ {"emqx.conf", do_fun("etc/emqx.conf")}
    , {"unescape.conf", do_fun("etc/unescape.conf")}
    ].

do_fun(File) ->
    fun() -> do(File) end.

do(File) ->
    {ok, Conf} = hocon:load(File),
    PP = hocon_pp:do(Conf, #{}),
    {ok, Conf2} = hocon:binary(iolist_to_binary(PP)),
    ?assertEqual(Conf, Conf2).

load_file_pp_test() ->
    TmpF = "/tmp/load_file_pp_test",
    F = fun (Raw, Format) ->
                ok = file:write_file(TmpF, Raw),
                {ok, M} = hocon:load(TmpF, #{format => Format}),
                Bin = flatten(M),
                [I || I <- binary:split(Bin, <<"\n">>, [global]), I =/= <<>>]
        end,
    ?assertEqual([ <<"f1 = 1 # /tmp/load_file_pp_test:3">>,
                   <<"foo = [] # /tmp/load_file_pp_test:1">>
                 ], F("foo=[]\n\nf1=1", richmap)),
    ?assertEqual([<<"f1 = 1 # /tmp/load_file_pp_test:2">>,
                  <<"foo.1 = \"a\" # /tmp/load_file_pp_test:1">>,
                  <<"foo.2 = \"b\" # /tmp/load_file_pp_test:1">>
                 ], F("foo=[a,b]\nf1=1", richmap)).

load_binary_pp_test() ->
    Sc = #{roots => [root],
           fields => #{root => [{"val", hoconsc:mk(hoconsc:ref(sub))}],
                       sub => [{"f1", integer()}]
                      }
          },
    Conf = "root = {val = {f1 = 43}}",
    {ok, Raw} = hocon:binary(Conf, #{format => richmap}),
    M1 = hocon_tconf:check(Sc, Raw, #{}),
    M2 = hocon_tconf:check_plain(Sc, Raw, #{}),
    %% print source as comment
    ?assertEqual(<<"root.val.f1 = 43 # line=1\n">>, flatten(M1)),
    %% no source info to print
    ?assertEqual(<<"root.val.f1 = 43\n">>, flatten(M2)),
    ok.

env_flat_pp_test() ->
    Sc = #{roots => [root],
           fields => #{root => [{"val", hoconsc:mk(hoconsc:ref(sub))}],
                       sub => [{"f1", integer()}]
                      }
          },
    Conf = "root = {val = {f1 = 43}}",
    {ok, Raw} = hocon:binary(Conf, #{format => richmap}),
    Check = fun(F) ->
                    with_envs(F, [Sc, Raw, #{apply_override_envs => true}],
                              [ {"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}
                              , {"EMQX_ROOT__VAL", "{f1:42}"}
                              ])
            end,
    M1 = Check(fun hocon_tconf:check/3),
    M2 = Check(fun hocon_tconf:check_plain/3),
    %% print source as comment
    ?assertEqual(<<"root.val.f1 = 42 # EMQX_ROOT__VAL\n">>, flatten(M1)),
    %% no source info to print
    ?assertEqual(<<"root.val.f1 = 42\n">>, flatten(M2)),
    ok.

with_envs(Fun, Args, Envs) -> hocon_test_lib:with_envs(Fun, Args, Envs).

flatten(Map) ->
    iolist_to_binary(hocon_pp:flat_dump(Map)).
