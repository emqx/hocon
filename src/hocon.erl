%%--------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon).

-export([load/1, load/2, files/1, files/2, binary/1, binary/2]).
-export([transform/2]).
-export([dump/2, dump/3]).
-export([main/1]).
-export([filename_of/1, line_of/1, value_of/1]).
-export([deep_merge/2]).

-export([duration/1]).

%% internal
-export([expand/1, resolve/1, concat/1]).

-type config() :: map().
-type ctx() :: #{
    path => list(),
    filename => list()
}.
-type convert() :: duration | bytesize | percent | onoff | convert_func().
-type convert_func() :: fun((term()) -> term()).
-type opts() :: #{
    format => map | proplists | richmap,
    convert => [convert()],
    include_dirs => [file:filename_all()]
}.

-export_type([config/0, ctx/0]).

-include("hocon.hrl").
-include("hocon_private.hrl").

-define(UNRESOLVABLE, '$unresolvable').

main(Args) ->
    hocon_cli:main(Args).

-spec load(file:filename()) -> {ok, config()} | {error, term()}.
load(Filename0) ->
    load(Filename0, #{format => map}).

-spec load(file:filename(), opts()) -> {ok, config()} | {error, term()}.
load(Filename0, Opts) ->
    Filename = hocon_util:real_file_name(filename:absname(Filename0)),
    IncludeDirs = maps:get(include_dirs, Opts, []),
    CtxList = [{path, '$root'}, {filename, Filename}, {include_dirs, IncludeDirs}],
    Ctx = hocon_util:stack_multiple_push(CtxList, #{}),
    try
        Bytes = hocon_token:read(Filename),
        Map = do_binary(Bytes, Ctx),
        Conf = transform(Map, Opts),
        {ok, apply_opts(Conf, Opts)}
    catch
        throw:Reason -> {error, Reason}
    end.

files(Files) ->
    files(Files, #{format => map}).

files(Files, Opts) ->
    IncludesAll = [include(Filename) || Filename <- Files],
    binary(IncludesAll, Opts).

include(Filename) when is_atom(Filename) ->
    include(atom_to_list(Filename));
include(Filename) when is_binary(Filename) ->
    include(unicode:characters_to_list(Filename, utf8));
include(Filename) ->
    ["include \"", esc(Filename), "\"\n"].

esc([]) -> [];
esc([$\\ | T]) -> [$\\, $\\ | esc(T)];
esc([$" | T]) -> [$\\, $" | esc(T)];
esc([H | T]) -> [H | esc(T)].

apply_opts(Map, Opts) ->
    ConvertedMap =
        case maps:find(convert, Opts) of
            {ok, Converter} ->
                hocon_postprocess:convert_value(Converter, Map);
            _ ->
                Map
        end,
    NullDeleted =
        case maps:find(delete_null, Opts) of
            {ok, true} ->
                hocon_postprocess:delete_null(ConvertedMap);
            _ ->
                ConvertedMap
        end,
    case maps:find(format, Opts) of
        {ok, proplists} ->
            hocon_postprocess:proplists(NullDeleted);
        _ ->
            NullDeleted
    end.

-spec binary(binary() | string()) -> {ok, config()} | {error, term()}.
binary(Binary) ->
    binary(Binary, #{format => map}).

binary(Binary, Opts) ->
    try
        IncludeDirs = maps:get(include_dirs, Opts, []),
        CtxList = [{path, '$root'}, {filename, undefined}, {include_dirs, IncludeDirs}],
        Ctx = hocon_util:stack_multiple_push(CtxList, #{}),
        Map = transform(do_binary(Binary, Ctx), Opts),
        {ok, apply_opts(Map, Opts)}
    catch
        throw:Reason -> {error, Reason}
    end.

%% @doc Recursively merge two maps.
%% There are two array representations supported
%% * as list, e.g. foo=[{bar=1},{bar=2}]
%% * as indexed-map: e.g. foo={"1"={bar=1},"2"={bar=2}}
%% When merging two values, if the `Base' is a list
%% indexed map elements respects the base representation, that is
%% the result of such merge is also a list.
%% Otherwise indexed-map is used.
%%
%% When both `Base' and `Override' are lists, the elements
%% are not merged, rather, the overriding-array replaces the whole base-array.
%%
%% NOTE: when merging indexed-map to list, the index boundary
%% is checked to ensure the elements are consecutive
-spec deep_merge(undefined | map(), map()) -> map().
deep_merge(Base, Override) -> hocon_maps:deep_merge(Base, Override).

do_binary(String, Ctx) when is_list(String) ->
    do_binary(unicode_bin(String), Ctx);
do_binary(Binary, Ctx) when is_binary(Binary) ->
    hocon_util:pipeline(
        Binary,
        Ctx,
        [
            fun hocon_token:scan/2,
            fun hocon_token:rm_trailing_comma/1,
            fun hocon_token:trans_key/1,
            fun hocon_token:parse/2,
            fun hocon_token:include/2,
            fun ?MODULE:expand/1,
            fun ?MODULE:resolve/1,
            fun ?MODULE:concat/1
        ]
    ).

dump(Config, App) ->
    [{App, to_list(Config)}].

dump(Config, App, Filename) ->
    file:write_file(Filename, io_lib:fwrite("~p.\n", [dump(Config, App)])).

to_list(Config) when is_map(Config) ->
    maps:to_list(maps:map(fun(_Key, MVal) -> to_list(MVal) end, Config));
to_list(Value) ->
    Value.

-spec expand(hocon_token:boxed()) -> hocon_token:boxed().
expand(#{?HOCON_T := object} = O) ->
    O#{?HOCON_V => do_expand(value_of(O), [])}.

do_expand([], Acc) ->
    lists:reverse(Acc);
do_expand([{#{?HOCON_T := key} = Key, #{?HOCON_T := concat} = C} | More], Acc) ->
    do_expand(More, [create_nested(Key, C#{?HOCON_V => do_expand(value_of(C), [])}) | Acc]);
do_expand([{#{?HOCON_T := key} = Key, Value} | More], Acc) ->
    do_expand(More, [create_nested(Key, Value) | Acc]);
do_expand([#{?HOCON_T := object} = O | More], Acc) ->
    do_expand(More, [O#{?HOCON_V => do_expand(value_of(O), [])} | Acc]);
do_expand([#{?HOCON_T := array, ?HOCON_V := V} = A | More], Acc) ->
    do_expand(More, [A#{?HOCON_V => do_expand(V, [])} | Acc]);
do_expand([#{?HOCON_T := concat, ?HOCON_V := V} = C | More], Acc) ->
    do_expand(More, [C#{?HOCON_V => do_expand(V, [])} | Acc]);
do_expand([Other | More], Acc) ->
    do_expand(More, [Other | Acc]).

create_nested(#{?HOCON_T := key} = Key, Value) ->
    case value_of(Key) of
        {keypath, Path} ->
            do_create_nested(Path, Value, Key);
        Path ->
            do_create_nested([Path], Value, Key)
    end.

do_create_nested([], Value, _OriginalKey) ->
    Value;
do_create_nested([Path | More], Value, OriginalKey) ->
    {maps:merge(OriginalKey, #{?HOCON_V => Path}), #{
        ?HOCON_T => concat, ?HOCON_V => [do_create_nested(More, Value, OriginalKey)]
    }}.

-spec resolve(hocon_token:boxed()) -> hocon_token:boxed().
resolve(#{?HOCON_T := object} = O) ->
    case do_resolve(value_of(O), [], [], value_of(O)) of
        skip ->
            O;
        {resolved, Resolved} ->
            resolve(O#{?HOCON_V => Resolved});
        {unresolved, Unresolved} ->
            resolve_error(lists:reverse(lists:flatten(Unresolved)))
    end.
do_resolve([], _Acc, [], _RootKVList) ->
    skip;
do_resolve([], _Acc, Unresolved, _RootKVList) ->
    {unresolved, Unresolved};
do_resolve([V | More], Acc, Unresolved, RootKVList) ->
    case do_resolve(V, [], [], RootKVList) of
        {resolved, Resolved} ->
            {resolved, lists:reverse(Acc, [Resolved | More])};
        {unresolved, Var} ->
            do_resolve(More, [V | Acc], [Var | Unresolved], RootKVList);
        skip ->
            do_resolve(More, [V | Acc], Unresolved, RootKVList);
        ?UNRESOLVABLE ->
            {resolved, lists:reverse(Acc, [?UNRESOLVABLE | More])}
    end;
do_resolve(#{?HOCON_T := T} = X, _Acc, _Unresolved, RootKVList) when ?IS_VALUE_LIST(T) ->
    case do_resolve(value_of(X), [], [], RootKVList) of
        {resolved, Resolved} ->
            {resolved, X#{?HOCON_V => Resolved}};
        {unresolved, Var} ->
            {unresolved, Var};
        skip ->
            skip
    end;
do_resolve(#{?HOCON_T := variable, required := Required} = V, _Acc, _Unresolved, RootKVList) ->
    case {lookup(paths(value_of(V)), RootKVList), Required} of
        {notfound, true} ->
            {unresolved, V};
        {notfound, false} ->
            ?UNRESOLVABLE;
        {ResolvedValue, _} ->
            {resolved, ResolvedValue}
    end;
do_resolve({#{?HOCON_T := key} = K, Value}, _Acc, _Unresolved, RootKVList) ->
    case do_resolve(Value, [], [], RootKVList) of
        {resolved, Resolved} ->
            {resolved, {K, Resolved}};
        {unresolved, Var} ->
            {unresolved, Var};
        skip ->
            skip
    end;
do_resolve(_Constant, _Acc, _Unresolved, _RootKVList) ->
    skip.

is_resolved(KV) ->
    case do_resolve(KV, [], [], []) of
        skip ->
            true;
        _ ->
            false
    end.

-spec lookup(list(), hocon_token:inbox()) -> hocon_token:boxed() | notfound.
lookup(Var, KVList) ->
    lookup(Var, KVList, notfound).

lookup(Var, #{?HOCON_T := concat} = C, ResolvedValue) ->
    lookup(Var, value_of(C), ResolvedValue);
lookup([Var], [{#{?HOCON_T := key, ?HOCON_V := Var}, Value} = KV | More], ResolvedValue) ->
    case is_resolved(KV) of
        true ->
            lookup([Var], More, maybe_merge(ResolvedValue, Value));
        false ->
            lookup([Var], More, ResolvedValue)
    end;
lookup(
    [Path | MorePath] = Var,
    [{#{?HOCON_T := key, ?HOCON_V := Path}, Value} | More],
    ResolvedValue
) ->
    lookup(Var, More, lookup(MorePath, Value, ResolvedValue));
lookup(Var, [#{?HOCON_T := T} = X | More], ResolvedValue) when T =:= concat orelse T =:= object ->
    lookup(Var, More, lookup(Var, value_of(X), ResolvedValue));
lookup(Var, [_Other | More], ResolvedValue) ->
    lookup(Var, More, ResolvedValue);
lookup(_Var, [], ResolvedValue) ->
    ResolvedValue.

% reveal the ?HOCON_T of "concat"
is_object([#{?HOCON_T := concat} = C | _More]) ->
    is_object(value_of(C));
is_object([#{?HOCON_T := object} | _]) ->
    true;
is_object(_Other) ->
    false.

maybe_merge(#{?HOCON_T := concat} = Old, #{?HOCON_T := concat} = New) ->
    case {is_object(value_of(Old)), is_object(value_of(New))} of
        {true, true} ->
            New#{?HOCON_V => lists:append([value_of(Old), value_of(New)])};
        _Other ->
            New
    end;
maybe_merge(_Old, New) ->
    New.

-spec concat(hocon_token:boxed()) -> hocon_token:boxed().
concat(#{?HOCON_T := object} = O) ->
    O#{?HOCON_V => lists:map(fun(E) -> verify_concat(E) end, value_of(O))}.

verify_concat(#{?HOCON_T := concat} = C) ->
    concat2(value_of(C), metadata_of(C));
verify_concat({#{?HOCON_T := key, ?METADATA := Metadata} = K, Value}) when is_map(Value) ->
    {K, verify_concat(Value#{?METADATA => Metadata})};
verify_concat({#{?HOCON_T := key} = K, Value}) ->
    {K, verify_concat(Value)};
verify_concat(Other) ->
    Other.

concat2(Concat, Location) ->
    concat2(Concat, Location, []).

concat2(Concats, Meta, Acc) ->
    %% If a substitution with the ${?foo} syntax is undefined:
    %%  * if it is the value of an object field then the field should not be created.
    %%    If the field would have overridden a previously-set value for the same field,
    %%    then the previous value remains.
    case lists:all(fun(I) -> I =:= ?UNRESOLVABLE end, Concats) of
        true ->
            ?UNRESOLVABLE;
        false ->
            do_concat(rm_unresolvable(Concats), Meta, Acc)
    end.

do_concat([], Meta, []) ->
    #{
        ?HOCON_T => object,
        % no fields
        ?HOCON_V => [],
        ?METADATA => Meta
    };
do_concat([], MetaKey, [{#{?METADATA := MetaFirstElem}, _V} = F | _Fs] = Acc) when ?IS_FIELD(F) ->
    Metadata = deep_merge(MetaFirstElem, MetaKey),
    case lists:all(fun(F0) -> ?IS_FIELD(F0) end, Acc) of
        true ->
            #{?HOCON_T => object, ?HOCON_V => lists:reverse(Acc), ?METADATA => Metadata};
        false ->
            concat_error(lists:reverse(Acc), #{?METADATA => Metadata})
    end;
do_concat([], MetaKey, [#{?HOCON_T := string, ?METADATA := MetaFirstElem} | _] = Acc) ->
    Metadata = deep_merge(MetaFirstElem, MetaKey),
    case lists:all(fun(A) -> type_of(A) =:= string end, Acc) of
        true ->
            BinList = lists:map(fun(M) -> maps:get(?HOCON_V, M) end, lists:reverse(Acc)),
            #{?HOCON_T => string, ?HOCON_V => unicode_bin(BinList), ?METADATA => Metadata};
        false ->
            concat_error(lists:reverse(Acc), #{?METADATA => Metadata})
    end;
do_concat([], MetaKey, [#{?HOCON_T := array, ?METADATA := MetaFirstElem} | _] = Acc) ->
    Metadata = deep_merge(MetaFirstElem, MetaKey),
    case lists:all(fun(A) -> type_of(A) =:= array end, Acc) of
        true ->
            NewValue = lists:append(lists:reverse(lists:map(fun value_of/1, Acc))),
            #{?HOCON_T => array, ?HOCON_V => NewValue, ?METADATA => Metadata};
        false ->
            concat_error(lists:reverse(Acc), #{?METADATA => Metadata})
    end;
do_concat([], Metadata, [_, _ | _] = Acc) ->
    concat_error(lists:reverse(Acc), #{?METADATA => Metadata});
do_concat([], _, [Acc]) ->
    Acc;
do_concat([#{?HOCON_T := array} = A | More], Metadata, Acc) ->
    do_concat(More, Metadata, [A#{?HOCON_V => lists:map(fun verify_concat/1, value_of(A))} | Acc]);
do_concat([#{?HOCON_T := object} = O | More], Metadata, Acc) ->
    ConcatO = lists:map(fun verify_concat/1, value_of(O)),
    do_concat(More, Metadata, lists:reverse(ConcatO, Acc));
do_concat([#{?HOCON_T := string} = S | More], Metadata, Acc) ->
    do_concat(More, Metadata, [S | Acc]);
do_concat([#{?HOCON_T := concat} = C | More], Metadata, Acc) ->
    ConcatC = concat2(value_of(C), new_meta(Metadata, filename_of(C), line_of(C))),
    do_concat([ConcatC | More], Metadata, Acc);
do_concat([{#{?HOCON_T := key} = K, Value} | More], Metadata, Acc) ->
    do_concat(More, Metadata, [{K, verify_concat(Value)} | Acc]);
do_concat([Other | More], Metadata, Acc) ->
    do_concat(More, Metadata, [Other | Acc]).

-spec transform(hocon_token:boxed(), map()) -> config().
transform(#{?HOCON_T := object, ?HOCON_V := V} = O, #{format := richmap} = Opts) ->
    NewV = do_transform(rm_unresolvable(V), #{}, Opts),
    O#{?HOCON_V => NewV};
transform(#{?HOCON_T := object, ?HOCON_V := V}, Opts) ->
    do_transform(rm_unresolvable(V), #{}, Opts).

do_transform([], Map, _Opts) ->
    Map;
do_transform([{Key, Value} | More], Map, Opts) ->
    KeyReal = unicode_bin(value_of(Key)),
    ValueReal = unpack(Value, Opts),
    do_transform(More, merge(KeyReal, ValueReal, Map), Opts).

unpack(#{?HOCON_T := object, ?HOCON_V := V} = O, #{format := richmap} = Opts) ->
    O#{?HOCON_V => do_transform(rm_unresolvable(V), #{}, Opts)};
unpack(#{?HOCON_T := object, ?HOCON_V := V}, Opts) ->
    do_transform(rm_unresolvable(V), #{}, Opts);
unpack(#{?HOCON_T := array, ?HOCON_V := V} = A, #{format := richmap} = Opts) ->
    NewV = [unpack(E, Opts) || E <- rm_unresolvable(V)],
    A#{?HOCON_V => NewV};
unpack(#{?HOCON_T := array, ?HOCON_V := V}, Opts) ->
    [unpack(Val, Opts) || Val <- rm_unresolvable(V)];
unpack(M, #{format := richmap}) ->
    M;
unpack(#{?HOCON_V := V}, _Opts) ->
    V.

rm_unresolvable(List) ->
    lists:filter(
        fun
            (?UNRESOLVABLE) -> false;
            ({_Key, ?UNRESOLVABLE}) -> false;
            (_Other) -> true
        end,
        List
    ).

paths(Key) when is_binary(Key) ->
    paths(unicode:characters_to_list(Key, utf8));
paths(Key) when is_list(Key) ->
    lists:map(fun unicode_bin/1, string:tokens(Key, ".")).

merge(Key, Val, Map) when is_map(Val) ->
    case maps:find(Key, Map) of
        {ok, MVal} ->
            maps:put(Key, hocon_maps:deep_merge(MVal, Val), Map);
        _Other ->
            maps:put(Key, Val, Map)
    end;
merge(Key, Val, Map) ->
    maps:put(Key, Val, Map).

resolve_error(Unresolved) ->
    NFL = fun(V) -> io_lib:format(", ~p ~s", [name_of(V), location(V)]) end,
    <<_LeadingComma, Enriched/binary>> = lists:foldl(
        fun(V, AccIn) ->
            unicode_bin([AccIn, NFL(V)])
        end,
        "",
        Unresolved
    ),
    throw({resolve_error, unicode_bin(["failed_to_resolve", Enriched])}).

concat_error(Acc, Metadata) ->
    ErrorInfo = io_lib:format("failed_to_concat ~p ~s", [format_tokens(Acc), location(Metadata)]),
    throw({concat_error, unicode_bin(ErrorInfo)}).

location(Metadata) ->
    io_lib:format("at_line ~p~s", [line_of(Metadata), maybe_filename(Metadata)]).

maybe_filename(Meta) ->
    case filename_of(Meta) of
        undefined -> "";
        F -> io_lib:format(" in_file ~s", [F])
    end.

% transforms tokens to values.
format_tokens(List) when is_list(List) ->
    lists:map(fun format_tokens/1, List);
format_tokens(#{?HOCON_T := array} = A) ->
    lists:map(fun format_tokens/1, value_of(A));
format_tokens({K, V}) ->
    {format_tokens(K), format_tokens(V)};
format_tokens(Token) ->
    value_of(Token).

value_of(Token) ->
    hocon_token:value_of(Token).

line_of(#{?METADATA := #{line := Line}}) ->
    Line;
line_of(_Other) ->
    undefined.

type_of(#{?HOCON_T := Type}) ->
    Type;
type_of(_Other) ->
    undefined.

filename_of(#{?METADATA := #{filename := Filename}}) ->
    Filename;
filename_of(_Other) ->
    undefined.

metadata_of(#{?METADATA := M}) ->
    M;
metadata_of(_Other) ->
    #{}.

name_of(#{?HOCON_T := variable, name := N}) ->
    N.

duration(X) ->
    hocon_postprocess:duration(X).

new_meta(Meta, Filename, Line) ->
    L = [{filename, Filename}, {line, Line}],
    NewMeta = maps:from_list([{N, V} || {N, V} <- L, V =/= undefined]),
    maps:merge(Meta, NewMeta).

unicode_bin(L) -> unicode:characters_to_binary(L, utf8).
