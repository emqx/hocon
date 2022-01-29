%%--------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-export([pipeline_fun/1, pipeline/3]).
-export([stack_multiple_push/2, stack_push/2, get_stack/2, top_stack/2]).
-export([is_same_file/2, real_file_name/1]).
-export([is_richmap/1, richmap_to_map/1]).
-export([env_prefix/1, is_array_index/1]).
-export([split_path/1, path_to_env_name/1]).

-include("hocon_private.hrl").

-define(IS_NON_EMPTY_STRING(X), (is_list(X) andalso X =/= [] andalso is_integer(hd(X)))).

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

%% @doc Check if it's a richmap.
%% A richmap always has a `?HOCON_V' field.
is_richmap(#{?HOCON_V := _}) -> true;
is_richmap([H | _]) -> is_richmap(H);
is_richmap(_) -> false.

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

is_array_index(L) when is_list(L) ->
    is_array_index(list_to_binary(L));
is_array_index(I) when is_binary(I) ->
    try
        {true, binary_to_integer(I)}
    catch
        _ : _ ->
            false
    end.

path_to_env_name(Path) ->
    string:uppercase(bin(lists:join("__", split_path(Path)))).

split_path(Path) ->
    lists:flatten(do_split(str(Path))).

do_split([]) -> [];
do_split(Path) when ?IS_NON_EMPTY_STRING(Path) ->
    [bin(I) || I <- string:tokens(Path, ".")];
do_split([H | T]) ->
    [do_split(H) | do_split(T)].

str(A) when is_atom(A) -> atom_to_list(A);
str(B) when is_binary(B) -> binary_to_list(B);
str(S) when is_list(S) -> S.

bin(S) -> iolist_to_binary(S).
