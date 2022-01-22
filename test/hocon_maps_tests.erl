%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(hocon_maps_tests).

-include_lib("eunit/include/eunit.hrl").
-include("hocon_private.hrl").

deep_put_test_() ->
    F = fun(Str, Key, Value) ->
                {ok, M} = hocon:binary(Str, #{format => richmap}),
                NewM = hocon_maps:deep_put(Key, Value, M, #{}),
                deep_get(Key, NewM, ?HOCON_V)
        end,
    [ ?_assertEqual(2, F("a=1", "a", 2))
    , ?_assertEqual(2, F("a={b=1}", "a.b", 2))
    , ?_assertEqual(#{x => 1}, F("a={b=1}", "a.b", #{x => 1}))
    ].

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
    case hocon_maps:deep_get(Path, Conf) of
        undefined -> undefined;
        Map -> maps:get(Param, Map, undefined)
    end.