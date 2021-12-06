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

-export([deep_map_merge/2, deep_merge/2]).
-export([pipeline_fun/1, pipeline/3]).
-export([stack_multiple_push/2, stack_push/2, get_stack/2, top_stack/2]).
-export([is_same_file/2, real_file_name/1]).
-export([richmap_to_map/1]).
-export([env_prefix/1, is_array_index/1]).
-export([update_array_element/3]).

-include("hocon_private.hrl").

deep_map_merge(M1, M2) when is_map(M1), is_map(M2) ->
    do_deep_merge(M1, M2, fun deep_map_merge/2);
deep_map_merge(_, Override) ->
    Override.

do_deep_merge(M1, M2, GoDeep) when is_map(M1), is_map(M2) ->
    maps:fold(
        fun(K, V2, Acc) ->
                V1 = maps:get(K, Acc, undefined),
                NewV = do_deep_merge(V1, V2, GoDeep),
                Acc#{K => NewV}
        end, M1, M2);
do_deep_merge(V1, V2, GoDeep) ->
    GoDeep(V1, V2).

deep_merge(#{?HOCON_T := array, ?HOCON_V := V1} = Base,
                 #{?HOCON_T := object, ?HOCON_V := V2} = Top) ->
    NewV = deep_merge2(V1, V2),
    case is_list(NewV) of
        true ->
            %% after merge, it's still an array, only update the value
            %% keep the metadata
            Base#{?HOCON_V => NewV};
        false ->
            %% after merge, it's no longer an array, return all old
            Top
    end;
deep_merge(V1, V2) ->
    deep_merge2(V1, V2).

deep_merge2(M1, M2) when is_map(M1) andalso is_map(M2) ->
    do_deep_merge(M1, M2, fun deep_merge/2);
deep_merge2(V1, V2) ->
    case is_list(V1) andalso is_indexed_array(V2) of
        true -> merge_array(V1, V2);
        false -> V2
    end.

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

is_same_file(A, B) ->
    real_file_name(A) =:= real_file_name(B).

real_file_name(F) ->
    case file:read_link_all(F) of
        {ok, Real} -> Real;
        {error, _} -> F
    end.

%% @doc Convert richmap to plain-map.
richmap_to_map(RichMap) when is_map(RichMap) ->
    richmap_to_map(maps:iterator(RichMap), #{});
richmap_to_map(Array) when is_list(Array) ->
    [richmap_to_map(R) || R <- Array];
richmap_to_map(Other) ->
    Other.

richmap_to_map(Iter, Map) ->
    case maps:next(Iter) of
        {?METADATA, _, I} ->
            richmap_to_map(I, Map);
        {?HOCON_T, _, I} ->
            richmap_to_map(I, Map);
        {?HOCON_V, M, _} when is_map(M) ->
            richmap_to_map(maps:iterator(M), #{});
        {?HOCON_V, A, _} when is_list(A) ->
            [richmap_to_map(R) || R <- A];
        {?HOCON_V, V, _} ->
            V;
        {K, V, I} ->
            richmap_to_map(I, Map#{K => richmap_to_map(V)});
        none ->
            Map
    end.

env_prefix(Default) ->
    case os:getenv("HOCON_ENV_OVERRIDE_PREFIX") of
        V when V =:= false orelse V =:= [] -> Default;
        Prefix -> Prefix
    end.

is_array_index(I) when is_binary(I) ->
    try
        {true, binary_to_integer(I)}
    catch
        _ : _ ->
            false
    end.

is_indexed_array(M) when is_map(M) ->
    lists:all(fun(K) -> case is_array_index(K) of
                            {true, _} -> true;
                            _ -> false
                        end
              end, maps:keys(M));
is_indexed_array(_) ->
    false.

%% convert indexed array to key-sorted tuple {index, value} list
indexed_array_as_list(M) when is_map(M) ->
    lists:keysort(
      1, lists:map(fun({K, V}) ->
                           {true, I} = is_array_index(K),
                           {I, V}
                   end, maps:to_list(M))).

merge_array(Array, Top) when is_list(Array) ->
    ToMerge = indexed_array_as_list(Top),
    do_merge_array(Array, ToMerge).

do_merge_array(Array, []) -> Array;
do_merge_array(Array, [{I, Value} | Rest]) ->
    GoDeep = fun(Elem) -> deep_merge(Elem, Value) end,
    NewArray = update_array_element(Array, I, GoDeep),
    do_merge_array(NewArray, Rest).

update_array_element(List, Index, GoDeep) when is_list(List) ->
    MinIndex = 1,
    MaxIndex = length(List) + 1,
    Index < MinIndex andalso throw({bad_array_index, "index starts from 1"}),
    Index > MaxIndex andalso
    begin
        Msg0 = io_lib:format("should not be greater than ~p.", [MaxIndex]),
        Msg1 = case Index > 9 of
                   true ->
                       "~nEnvironment variable overrides applied in alphabetical "
                       "make sure to use zero paddings such as '02' to ensure "
                       "10 is ordered after it";
                   false ->
                       []
               end,
        throw({bad_array_index, [Msg0, Msg1]})
    end,
    {Head, Tail0} = lists:split(Index - 1, List),
    {Nth, Tail} = case Tail0 of
                      [] -> {#{}, []};
                      [H | T] -> {H, T}
                  end,
    Head ++ [GoDeep(Nth) | Tail].
