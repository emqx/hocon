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
-export([
    deep_get/2,
    deep_put/4,
    deep_merge/2
]).

%% Access maybe-rich map values,
%% Always return plain value.
-export([get/2, get/3]).

-export([flatten/2]).

%% internal
-export([do_put/4]).

-export([ensure_plain/1, is_richmap/1]).

-include("hocon_private.hrl").

-define(EMPTY_MAP, #{}).

-type config() :: hocon:config().

%% this can be the opts() from hocon_tconf, but only `atom_key' is relevant
-type opts() :: #{
    atom_key => boolean(),
    _ => _
}.

-type flatten_opts() :: #{rich_value => boolean()}.

%% @doc put unboxed value to the richmap box
%% this function is called places where there is no boxing context
%% so it has to accept unboxed value.
-spec deep_put(string(), term(), config(), opts()) -> config().
deep_put(Path, Value, Conf, Opts) ->
    put_rich(Opts, hocon_util:split_path(Path), Value, Conf).

put_rich(_Opts, [], Value, Box) ->
    maybe_boxit(Value, Box);
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

maybe_array(#{?HOCON_V := V}) -> maybe_array(V);
maybe_array(V) when is_list(V) -> true;
maybe_array(V) -> V =:= ?EMPTY_MAP.

update_array_element(#{?HOCON_V := V} = Box, Index, GoDeep) ->
    boxit(update_array_element(V, Index, GoDeep), Box);
update_array_element(?EMPTY_MAP, Index, GoDeep) ->
    update_array_element([], Index, GoDeep);
update_array_element(List, Index, GoDeep) when is_list(List) ->
    do_update_array_element(List, Index, GoDeep).

update_map_field(Opts, Map, FieldName, GoDeep) ->
    FieldV0 = maps:get(FieldName, Map, ?EMPTY_MAP),
    FieldV = GoDeep(FieldV0),
    Map1 = maps:without([FieldName], Map),
    Map1#{maybe_atom(Opts, FieldName) => FieldV}.

maybe_atom(#{atom_key := true}, Name) when is_binary(Name) ->
    try
        binary_to_existing_atom(Name, utf8)
    catch
        _:_ ->
            error({non_existing_atom, Name})
    end;
maybe_atom(_Opts, Name) ->
    Name.

safe_unbox(MaybeBox) ->
    case maps:get(?HOCON_V, MaybeBox, undefined) of
        undefined -> ?EMPTY_MAP;
        Value -> Value
    end.

%% the provided boxed value may have its own metadata
%% we try to keep the override information
maybe_boxit(#{?HOCON_V := _} = V, _Box) -> V;
maybe_boxit(V, Box) -> boxit(V, Box).

boxit(Value, Box) -> Box#{?HOCON_V => Value}.

%% @doc Get value from a plain or rich map.
%% `undefined' is returned if no such value path.
%% NOTE: always return plain-value.
-spec get([nonempty_string()] | nonempty_string(), config(), term()) -> term().
get(Path, Config, Default) ->
    case get(Path, Config) of
        undefined -> Default;
        V -> V
    end.

%% @doc get a child node from richmap, return value also a richmap.
%% `undefined' is returned if no value path.
%% Key (first arg) can be "foo.bar.baz" or ["foo.bar", "baz"] or ["foo", "bar", "baz"].
-spec deep_get(string() | [string()], config()) -> config() | undefined.
deep_get(Path, Conf) ->
    do_get(hocon_util:split_path(Path), Conf, richmap).

%% @doc Get value from a maybe-rich map.
%% always return plain-value.
-spec get([nonempty_string()] | nonempty_string(), config()) -> term().
get(Path, Map) ->
    case is_richmap(Map) of
        true ->
            C = deep_get(Path, Map),
            hocon_util:richmap_to_map(C);
        false ->
            do_get(hocon_util:split_path(Path), Map, map)
    end.

do_get([], Conf, _Format) ->
    Conf;
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
                error:badarg ->
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
        error:badarg ->
            undefined
    end;
%% get(["a", "b", "d"], #{<<"a">> => #{<<"b">> => 1}})
try_get(Key, Conf, map) ->
    error({key_not_found, Key, Conf}).

%% @doc Recursively merge two maps.
%% @see hocon:deep_merge/2 for more.
deep_merge(
    #{?HOCON_T := array, ?HOCON_V := V1} = Base,
    #{?HOCON_T := object, ?HOCON_V := V2} = Top
) ->
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

do_deep_merge(M1, M2, GoDeep) when is_map(M1), is_map(M2) ->
    maps:fold(
        fun(K, V2, Acc) ->
            V1 = maps:get(K, Acc, undefined),
            NewV = do_deep_merge(V1, V2, GoDeep),
            Acc#{K => NewV}
        end,
        M1,
        M2
    );
do_deep_merge(V1, V2, GoDeep) ->
    GoDeep(V1, V2).

is_indexed_array(M) when is_map(M) ->
    lists:all(
        fun(K) ->
            case is_array_index(K) of
                {true, _} -> true;
                _ -> false
            end
        end,
        maps:keys(M)
    );
is_indexed_array(_) ->
    false.

%% convert indexed array to key-sorted tuple {index, value} list
indexed_array_as_list(M) when is_map(M) ->
    lists:keysort(
        1,
        lists:map(
            fun({K, V}) ->
                {true, I} = is_array_index(K),
                {I, V}
            end,
            maps:to_list(M)
        )
    ).

merge_array(Array, Top) when is_list(Array) ->
    ToMerge = indexed_array_as_list(Top),
    do_merge_array(Array, ToMerge).

do_merge_array(Array, []) ->
    Array;
do_merge_array(Array, [{I, Value} | Rest]) ->
    GoDeep = fun(Elem) -> deep_merge(Elem, Value) end,
    NewArray = do_update_array_element(Array, I, GoDeep),
    do_merge_array(NewArray, Rest).

do_update_array_element(List, Index, GoDeep) when is_list(List) ->
    MinIndex = 1,
    MaxIndex = length(List) + 1,
    Index < MinIndex andalso throw({bad_array_index, "index starts from 1"}),
    Index > MaxIndex andalso
        begin
            Msg0 = io_lib:format("should not be greater than ~p.", [MaxIndex]),
            Msg1 =
                case Index > 9 of
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
    {Nth, Tail} =
        case Tail0 of
            [] -> {#{}, []};
            [H | T] -> {H, T}
        end,
    Head ++ [GoDeep(Nth) | Tail].

is_array_index(Maybe) ->
    hocon_util:is_array_index(Maybe).

%% @doc Flatten out a deep-nested map to {<<"path.to.value">>, Value} pairs
%% If `rich_value' is provided `true' in `Opts', the value is a map with
%% metadata.
-spec flatten(config(), flatten_opts()) -> [{binary(), term()}].
flatten(Conf, Opts) ->
    lists:reverse(flatten(Conf, Opts, undefined, [], [])).

flatten(Conf, Opts, Meta, Stack, Acc) when is_list(Conf) andalso Conf =/= [] ->
    flatten_l(Conf, Opts, Meta, Stack, Acc, lists:seq(1, length(Conf)));
flatten(#{?HOCON_V := Value} = Conf, Opts, _Meta, Stack, Acc) ->
    Meta = maps:get(?METADATA, Conf, undefined),
    flatten(Value, Opts, Meta, Stack, Acc);
flatten(Conf, Opts, Meta, Stack, Acc) when is_map(Conf) andalso Conf =/= ?EMPTY_MAP ->
    {Keys, Values} = lists:unzip(maps:to_list(Conf)),
    flatten_l(Values, Opts, Meta, Stack, Acc, Keys);
flatten(Value, Opts, Meta, Stack, Acc) ->
    V =
        case maps:get(rich_value, Opts, false) of
            true -> #{?HOCON_V => Value, ?METADATA => Meta};
            false -> Value
        end,
    [{unicode_bin(infix(lists:reverse(Stack), ".")), V} | Acc].

flatten_l([], _Opts, _Meta, _Stack, Acc, []) ->
    Acc;
flatten_l([H | T], Opts, Meta, Stack, Acc, [Tag | Tags]) ->
    NewAcc = flatten(H, Opts, Meta, [bin(Tag) | Stack], Acc),
    flatten_l(T, Opts, Meta, Stack, NewAcc, Tags).

bin(B) when is_binary(B) -> B;
bin(I) when is_integer(I) -> integer_to_binary(I).

infix([], _) -> [];
infix([X], _) -> [X];
infix([H | T], I) -> [H, I | infix(T, I)].

ensure_plain(M) ->
    case is_richmap(M) of
        true -> hocon_util:richmap_to_map(M);
        false -> M
    end.

%% @doc Check if it's a richmap.
%% A richmap always has a `?HOCON_V' field.
is_richmap(M) -> hocon_util:is_richmap(M).

unicode_bin(L) -> unicode:characters_to_binary(L, utf8).
