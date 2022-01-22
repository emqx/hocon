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

-module(hocon_maps).

%% Deep ops of deep maps.
-export([deep_get/2, deep_put/4]).

%% Access maybe-rich map values,
%% Always reutrn plain value.
-export([get/2, get/3]).

-export([do_put/4]). %% internal

-include("hocon_private.hrl").

-define(EMPTY_MAP, #{}).

%% this can be the opts() from hocon_tconf, but only `atom_key' is relevant
-type opts() :: #{atom_key => boolean(),
                  _ => _}.

%% @doc put unboxed value to the richmap box
%% this function is called places where there is no boxing context
%% so it has to accept unboxed value.
-spec deep_put(string(), term(), hocon:config(), opts()) -> hocon:config().
deep_put(Path, Value, Conf, Opts) ->
    put_rich(Opts, hocon_util:split_path(Path), Value, Conf).

put_rich(_Opts, [], Value, Box) ->
    boxit(Value, Box);
put_rich(Opts, [Name | Path], Value, Box) ->
    V0 = safe_unbox(Box),
    GoDeep = fun(Elem) -> put_rich(Opts, Path, Value, Elem) end,
    V = do_put(V0, Name, GoDeep, Opts),
    boxit(V, Box).

do_put(V, Name, GoDeep, Opts) ->
    case maybe_array(V) andalso hocon_util:is_array_index(Name) of
        {true, Index} -> update_array_element(V, Index, GoDeep);
        false when is_map(V) -> update_map_field(Opts, V, Name, GoDeep);
        false -> update_map_field(Opts, #{}, Name, GoDeep)
    end.

maybe_array(V) when is_list(V) -> true;
maybe_array(V) -> V =:= ?EMPTY_MAP.

update_array_element(?EMPTY_MAP, Index, GoDeep) ->
    update_array_element([], Index, GoDeep);
update_array_element(List, Index, GoDeep) when is_list(List) ->
    hocon_util:update_array_element(List, Index, GoDeep).

update_map_field(Opts, Map, FieldName, GoDeep) ->
    FieldV0 = maps:get(FieldName, Map, ?EMPTY_MAP),
    FieldV = GoDeep(FieldV0),
    Map1 = maps:without([FieldName], Map),
    Map1#{maybe_atom(Opts, FieldName) => FieldV}.

maybe_atom(#{atom_key := true}, Name) when is_binary(Name) ->
    try
        binary_to_existing_atom(Name, utf8)
    catch
        _ : _ ->
            error({non_existing_atom, Name})
    end;
maybe_atom(_Opts, Name) ->
    Name.

safe_unbox(MaybeBox) ->
    case maps:get(?HOCON_V, MaybeBox, undefined) of
        undefined -> ?EMPTY_MAP;
        Value -> Value
    end.

boxit(Value, Box) -> Box#{?HOCON_V => Value}.

%% @doc Get value from a plain or rich map.
%% `undefined' is returned if no such value path.
%% NOTE: always return plain-value.
-spec get(string(), hocon:config(), term()) -> term().
get(Path, Config, Default) ->
    case get(Path, Config) of
        undefined -> Default;
        V -> V
    end.

%% @doc get a child node from richmap, return value also a richmap.
%% `undefined' is returned if no value path.
%% Key (first arg) can be "foo.bar.baz" or ["foo.bar", "baz"] or ["foo", "bar", "baz"].
-spec deep_get(string() | [string()], hocon:config()) -> hocon:config() | undefined.
deep_get(Path, Conf) ->
    do_get(hocon_util:split_path(Path), Conf, richmap).

%% @doc Get value from a maybe-rich map.
%% always return plain-value.
-spec get(string(), hocon:config()) -> term().
get(Path, Map) ->
    case hocon_util:is_richmap(Map) of
        true ->
            C = deep_get(Path, Map),
            hocon_util:richmap_to_map(C);
        false ->
            do_get(hocon_util:split_path(Path), Map, map)
    end.

do_get([], Conf, _Format) -> Conf;
do_get([H | T], Conf, Format) ->
    FieldV = try_get(H, Conf, Format),
    do_get(T, FieldV, Format).

try_get(_Key, undefined, _Format) ->
    undefined;
try_get(Key, Conf, richmap) ->
    #{?HOCON_V := V} = Conf,
    try_get(Key, V, map);
try_get(Key, Conf, map) when is_map(Conf) ->
    case maps:get(Key, Conf, undefined) of
        undefined ->
            try binary_to_existing_atom(Key, utf8) of
                AtomKey -> maps:get(AtomKey, Conf, undefined)
            catch
                error : badarg ->
                    undefined
            end;
        Value ->
            Value
    end;
try_get(Key, Conf, map) when is_list(Conf) ->
    try binary_to_integer(Key) of
        N ->
            lists:nth(N, Conf)
    catch
        error : badarg ->
            undefined
    end.
