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

pp_test_() ->
    [ {"emqx.conf", do_fun("etc/emqx.conf")}
    ].

do_fun(File) ->
    fun() -> do(File) end.

do(File) ->
    {ok, Conf} = hocon:load(File),
    PP = hocon_pp:do(Conf, #{}),
    {ok, Conf2} = hocon:binary(iolist_to_binary(PP)),
    ?assertEqual(Conf, Conf2).
