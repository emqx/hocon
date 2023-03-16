%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon_util_tests).

-include_lib("eunit/include/eunit.hrl").

richmap_to_map_test_() ->
    F = fun(Str) ->
        {ok, M} = hocon:binary(Str, #{format => richmap}),
        richmap_to_map(M)
    end,
    [
        ?_assertEqual(#{<<"a">> => #{<<"b">> => 1}}, F("a.b=1")),
        ?_assertEqual(#{<<"a">> => #{<<"b">> => [1, 2, 3]}}, F("a.b = [1,2,3]")),
        ?_assertEqual(
            #{
                <<"a">> =>
                    #{<<"b">> => [1, 2, #{<<"x">> => <<"foo">>}]}
            },
            F("a.b = [1,2,{x=foo}]")
        )
    ].

richmap_to_map(Map) ->
    hocon_util:richmap_to_map(Map).
