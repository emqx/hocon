%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon_postprocess).

-export([proplists/1]).
-export([convert_value/2]).
-export([delete_null/1]).
-export([duration/1, bytesize/1, onoff/1, percent/1]).

-include("hocon.hrl").

proplists(Map) when is_map(Map) ->
    lists:reverse(proplists(maps:iterator(Map), [], [])).
proplists(Iter, Path, Acc) ->
    case maps:next(Iter) of
        {K, M, I} when is_map(M) ->
            Child = proplists(maps:iterator(M), [unicode_list(K) | Path], []),
            proplists(I, Path, lists:append(Child, Acc));
        {K, [Bin | _More] = L, I} when is_binary(Bin) ->
            NewList = [unicode_list(B) || B <- L],
            ReversedPath = lists:reverse([unicode_list(K) | Path]),
            proplists(I, Path, [{ReversedPath, NewList} | Acc]);
        {K, Bin, I} when is_binary(Bin) ->
            ReversedPath = lists:reverse([unicode_list(K) | Path]),
            proplists(I, Path, [{ReversedPath, unicode_list(Bin)} | Acc]);
        {K, V, I} ->
            ReversedPath = lists:reverse([unicode_list(K) | Path]),
            proplists(I, Path, [{ReversedPath, V} | Acc]);
        none ->
            Acc
    end.

convert_value(ConvertFunctions, Map) when is_list(ConvertFunctions) ->
    Resolved = resolve_convert_fun(ConvertFunctions),
    do_convert_value(hocon_util:pipeline_fun(Resolved), Map).

do_convert_value(Fun, Map) ->
    do_convert_value(Fun, maps:iterator(Map), #{}).
do_convert_value(Fun, I, NewMap) ->
    case maps:next(I) of
        {K, M, Next} when is_map(M) ->
            do_convert_value(Fun, Next, NewMap#{K => do_convert_value(Fun, M)});
        {K, V, Next} ->
            do_convert_value(Fun, Next, NewMap#{K => Fun(V)});
        none ->
            NewMap
    end.

resolve_convert_fun(L) when is_list(L) ->
    lists:map(fun do_resolve_convert_fun/1, L).
do_resolve_convert_fun(duration) ->
    fun duration/1;
do_resolve_convert_fun(onoff) ->
    fun onoff/1;
do_resolve_convert_fun(bytesize) ->
    fun bytesize/1;
do_resolve_convert_fun(percent) ->
    fun percent/1;
do_resolve_convert_fun(F) when is_function(F, 1) ->
    F.

delete_null(Map) when is_map(Map) ->
    delete_null(maps:iterator(Map), #{}).
delete_null(Iter, NewMap) ->
    case maps:next(Iter) of
        {K, M, Next} when is_map(M) ->
            case delete_null(M) of
                EmptyM when map_size(EmptyM) =:= 0 ->
                    delete_null(Next, NewMap);
                NewM ->
                    delete_null(Next, NewMap#{K => NewM})
            end;
        {K, V, Next} ->
            case is_null(V) of
                true ->
                    delete_null(Next, NewMap);
                false ->
                    delete_null(Next, NewMap#{K => V})
            end;
        none ->
            NewMap
    end.

is_null(null) -> true;
is_null(_Other) -> false.

onoff(Bin) when is_binary(Bin) ->
    Str = unicode_list(Bin),
    case do_onoff(Str) of
        Bool when Bool =:= true orelse Bool =:= false ->
            Bool;
        Str when is_list(Str) ->
            unicode_bin(Str)
    end;
onoff(Str) when is_list(Str) ->
    do_onoff(Str);
onoff(Other) ->
    Other.

do_onoff("on") -> true;
do_onoff("off") -> false;
do_onoff(X) -> X.

re_run_first(Str, MP) ->
    re:run(Str, MP, [{capture, all_but_first, list}]).

percent(Bin) when is_binary(Bin) ->
    case do_percent(unicode_list(Bin)) of
        Percent when is_float(Percent) ->
            Percent;
        Str when is_list(Str) ->
            unicode_bin(Str)
    end;
percent(Str) when is_list(Str) ->
    do_percent(Str);
percent(Other) ->
    Other.

do_percent(Str) ->
    {ok, MP} = re:compile("([0-9]+)(%)$"),
    case re_run_first(Str, MP) of
        {match, [Val, _Unit]} ->
            list_to_integer(Val) / 100;
        _ ->
            Str
    end.

bytesize(Bin) when is_binary(Bin) ->
    case do_bytesize(unicode_list(Bin)) of
        Byte when is_integer(Byte) ->
            Byte;
        Str when is_list(Str) ->
            unicode_bin(Str)
    end;
bytesize(Str) when is_list(Str) ->
    do_bytesize(Str);
bytesize(Other) ->
    Other.

do_bytesize(Str) ->
    {ok, MP} = re:compile("([0-9]+)(kb|KB|mb|MB|gb|GB)$"),
    case re_run_first(Str, MP) of
        {match, [Val, Unit]} ->
            do_bytesize(list_to_integer(Val), Unit);
        _ ->
            Str
    end.
do_bytesize(Val, "kb") -> Val * ?KILOBYTE;
do_bytesize(Val, "KB") -> Val * ?KILOBYTE;
do_bytesize(Val, "mb") -> Val * ?MEGABYTE;
do_bytesize(Val, "MB") -> Val * ?MEGABYTE;
do_bytesize(Val, "gb") -> Val * ?GIGABYTE;
do_bytesize(Val, "GB") -> Val * ?GIGABYTE.

duration(Bin) when is_binary(Bin) ->
    case do_duration(unicode_list(Bin)) of
        Duration when is_integer(Duration) ->
            Duration;
        Unchanged when is_list(Unchanged) ->
            Bin
    end;
duration(Str) when is_list(Str) ->
    do_duration(Str);
duration(Other) ->
    Other.

do_duration(Str) ->
    case do_duration(Str, 0) of
        skip -> Str;
        Num -> round(Num)
    end.
do_duration(Str, Sum) ->
    {ok, MP} = re:compile("^([0-9\.]+)(f|F|w|W|d|D|h|H|m|M|s|S|ms|MS)([0-9\.]+.+)"),
    case re_run_first(Str, MP) of
        {match, [Val, Unit, Next]} ->
            do_duration(Next, Sum + calc_duration(get_decimal(Val), string:lowercase(Unit)));
        nomatch ->
            {ok, LastMP} = re:compile("^([0-9\.]+)(f|F|w|W|d|D|h|H|m|M|s|S|ms|MS)$"),
            case re_run_first(Str, LastMP) of
                {match, [Val, Unit]} ->
                    Sum + calc_duration(get_decimal(Val), string:lowercase(Unit));
                nomatch ->
                    skip
            end
    end.

get_decimal([$. | _] = Num) ->
    get_decimal(["0" | Num]);
get_decimal(Num) ->
    case string:to_float(Num) of
        {F, []} ->
            F;
        {error, no_float} ->
            {I, []} = string:to_integer(Num),
            I
    end.

calc_duration(Val, "f") -> Val * ?FORTNIGHT;
calc_duration(Val, "w") -> Val * ?WEEK;
calc_duration(Val, "d") -> Val * ?DAY;
calc_duration(Val, "h") -> Val * ?HOUR;
calc_duration(Val, "m") -> Val * ?MINUTE;
calc_duration(Val, "s") -> Val * ?SECOND;
calc_duration(Val, "ms") -> Val.

unicode_list(B) when is_binary(B) -> unicode:characters_to_list(B, utf8).

unicode_bin(L) when is_list(L) -> unicode:characters_to_binary(L, utf8).
