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

-module(hocon_util).

-export([do_deep_merge/2]).
-export([pipeline_fun/1, pipeline/3]).
-export([stack_multiple_push/2, stack_push/2, get_stack/2, top_stack/2]).

do_deep_merge(M1, M2) when is_map(M1), is_map(M2) ->
    maps:fold(fun(K, V2, Acc) ->
        case Acc of
            #{K := V1} ->
                Acc#{K => do_deep_merge(V1, V2)};
            _ ->
                Acc#{K => V2}
        end
              end, M1, M2);
do_deep_merge(_, Override) ->
    Override.

pipeline_fun(Steps) ->
    fun (Input) -> pipeline(Input, #{}, Steps) end.

pipeline(Input, Ctx, [Fun | Steps]) ->
    Output = case is_function(Fun, 1) of
        true -> Fun(Input);
        false -> Fun(Input, Ctx)
    end,
    pipeline(Output, Ctx, Steps);
pipeline(Result, _Ctx, []) -> Result.

stack_multiple_push(List, Ctx) ->
    lists:foldl(fun stack_push/2, Ctx, List).

stack_push({Key, Value}, Ctx) ->
    Stack = get_stack(Key, Ctx),
    Ctx#{Key => [Value | Stack]}.

get_stack(Key, Ctx) -> maps:get(Key, Ctx, []).
top_stack(Key, Ctx) -> hd(get_stack(Key, Ctx)).
