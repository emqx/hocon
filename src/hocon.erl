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

-module(hocon).

-export([load/1, load/2, binary/1]).
-export([dump/2, dump/3]).
-export([main/1]).

% cuttlefish uses duration/1 in
-export([duration/1]).

-type config() :: map().
-type ctx() :: #{path => list(),
                 filename => list()}.
-type convert() :: duration | bytesize | percent | onoff | convert_func().
-type convert_func() :: fun((term()) -> term()).
-type opts() :: #{format => map | proplists,
                  convert => [convert()]}.

-export_type([config/0, ctx/0]).

-include("hocon.hrl").

main(Args) ->
    hocon_cli:main(Args).

-spec(load(file:filename()) -> {ok, config()} | {error, term()}).
load(Filename0) ->
    load(Filename0, #{format => map}).

-spec(load(file:filename(), opts()) -> {ok, config()} | {error, term()}).
load(Filename0, Opts) ->
    Filename = hocon_util:real_file_name(filename:absname(Filename0)),
    Ctx = hocon_util:stack_multiple_push([{path, '$root'}, {filename, Filename}], #{}),
    try
        Bytes = hocon_token:read(Filename),
        Map = do_binary(Bytes, Ctx),
        {ok, apply_opts(Map, Opts)}
    catch
        throw:Reason -> {error, Reason}
    end.

apply_opts(Map, Opts) ->
    ConvertedMap = case maps:find(convert, Opts) of
        {ok, Converter} ->
            hocon_postprocess:convert_value(Converter, Map);
        _ ->
            Map
    end,
    NullDeleted = case maps:find(delete_null, Opts) of
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
    try
        Ctx = hocon_util:stack_multiple_push([{path, '$root'}, {filename, undefined}], #{}),
        {ok, do_binary(Binary, Ctx)}
    catch
        throw:Reason -> {error, Reason}
    end.

do_binary(Binary, Ctx) ->
    hocon_util:pipeline(Binary, Ctx,
                       [ fun hocon_token:scan/2
                       , fun hocon_token:trans_key/1
                       , fun hocon_token:parse/2
                       , fun hocon_token:include/2
                       , fun expand/1
                       , fun resolve/1
                       , fun concat/1
                       , fun transform/1
                       ]).

dump(Config, App) ->
    [{App, to_list(Config)}].

dump(Config, App, Filename) ->
    file:write_file(Filename, io_lib:fwrite("~p.\n", [dump(Config, App)])).

to_list(Config) when is_map(Config) ->
    maps:to_list(maps:map(fun(_Key, MVal) -> to_list(MVal) end, Config));
to_list(Value) -> Value.

-spec(expand(hocon_token:boxed()) -> hocon_token:boxed()).
expand(#{type := object}=O) ->
    O#{value => do_expand(value_of(O), [])}.

do_expand([], Acc) ->
    lists:reverse(Acc);
do_expand([{#{type := key}=Key, #{type := concat}=C} | More], Acc) ->
    do_expand(More, [create_nested(Key, C#{value => do_expand(value_of(C), [])}) | Acc]);
do_expand([{#{type := key}=Key, Value} | More], Acc) ->
    do_expand(More, [create_nested(Key, Value) | Acc]);
do_expand([#{type := object}=O | More], Acc)  ->
    do_expand(More, [O#{value => do_expand(value_of(O), [])} | Acc]);
do_expand([Other | More], Acc) ->
    do_expand(More, [Other | Acc]).

create_nested(#{type := key}=Key, Value)  ->
    do_create_nested(paths(value_of(Key)), Value, Key).

do_create_nested([], Value, _OriginalKey) ->
    Value;
do_create_nested([Path | More], Value, OriginalKey) ->
    {maps:merge(OriginalKey, #{value => Path}),
     #{type => concat, value => [do_create_nested(More, Value, OriginalKey)]}}.

-spec(resolve(hocon_token:boxed()) -> hocon_token:boxed()).
resolve(#{type := object}=O) ->
    case do_resolve(value_of(O), [], [], value_of(O)) of
        skip ->
            O;
        {resolved, Resolved} ->
            resolve(O#{value => Resolved});
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
        delete ->
            {resolved, lists:reverse(Acc, More)}
    end;
do_resolve(#{type := T}=X, _Acc, _Unresolved, RootKVList) when ?IS_VALUE_LIST(T) ->
    case do_resolve(value_of(X), [], [], RootKVList) of
        {resolved, Resolved} ->
            {resolved, X#{value => Resolved}};
        {unresolved, Var} ->
            {unresolved, Var};
        skip ->
            skip
    end;
do_resolve(#{type := variable, required := Required}=V, _Acc, _Unresolved, RootKVList) ->
    case {lookup(paths(hocon_token:value_of(V)), RootKVList), Required} of
        {notfound, true} ->
            {unresolved, V};
        {notfound, false} ->
            delete;
        {ResolvedValue, _} ->
            {resolved, ResolvedValue}
    end;
do_resolve({#{type := key}=K, Value}, _Acc, _Unresolved, RootKVList) ->
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

-spec(lookup(list(), hocon_token:inbox()) -> hocon_token:boxed() | notfound).
lookup(Var, KVList) ->
    lookup(Var, KVList, notfound).

lookup(Var, #{type := concat}=C, ResolvedValue) ->
    lookup(Var, value_of(C), ResolvedValue);
lookup([Var], [{#{type := key, value := Var}, Value} = KV | More], ResolvedValue) ->
    case is_resolved(KV) of
        true ->
            lookup([Var], More, maybe_merge(ResolvedValue, Value));
        false ->
            lookup([Var], More, ResolvedValue)
    end;
lookup([Path | MorePath] = Var, [{#{type := key, value := Path}, Value} | More], ResolvedValue) ->
    lookup(Var, More, lookup(MorePath, Value, ResolvedValue));
lookup(Var, [#{type := T}=X | More], ResolvedValue) when T =:= concat orelse T =:= object ->
    lookup(Var, More, lookup(Var, value_of(X), ResolvedValue));
lookup(Var, [_Other | More], ResolvedValue) ->
    lookup(Var, More, ResolvedValue);
lookup(_Var, [], ResolvedValue) ->
    ResolvedValue.

% reveal the type of "concat"
is_object([#{type := concat}=C | _More]) ->
    is_object(value_of(C));
is_object([#{type := object} | _]) ->
    true;
is_object(_Other) ->
    false.

maybe_merge(#{type := concat}=Old, #{type := concat}=New) ->
    case {is_object(value_of(Old)), is_object(value_of(New))} of
        {true, true} ->
            New#{value =>lists:append([value_of(Old), value_of(New)])};
        _Other ->
            New
    end;
maybe_merge(_Old, New) ->
    New.

-spec concat(hocon_token:boxed()) -> hocon_token:boxed().
concat(#{type := object}=O) ->
    O#{value => lists:map(fun (E) -> verify_concat(E) end, value_of(O))}.

verify_concat(#{type := concat}=C) ->
    do_concat(value_of(C), #{line => line_of(C), filename => filename_of(C)});
verify_concat({#{type := key}=K, Value}) ->
    {K, verify_concat(Value)};
verify_concat(Other) ->
    Other.

do_concat(Concat, Location) ->
    do_concat(Concat, Location, []).

do_concat([], _, []) ->
    nothing;
do_concat([], Location, [Field | _Fields] = Acc) when ?IS_FIELD(Field) ->
    case lists:all(fun (F) -> ?IS_FIELD(F) end, Acc) of
        true ->
            Location#{type => object, value => lists:reverse(Acc)};
        false ->
            concat_error(lists:reverse(Acc), Location)
    end;
do_concat([], Location, [#{type:= string} | _] = Acc) ->
    case lists:all(fun (A) -> type_of(A) =:= string end, Acc) of
        true ->
            BinList = lists:map(fun(M) -> maps:get(value, M) end, lists:reverse(Acc)),
            Location#{type => string, value => iolist_to_binary(BinList)};
        false ->
            concat_error(lists:reverse(Acc), Location)
    end;
do_concat([], Location, [#{type := array} | _] = Acc) ->
    case lists:all(fun (A) -> type_of(A) =:= array end, Acc) of
        true ->
            NewValue = lists:append(lists:reverse(lists:map(fun value_of/1, Acc))),
            Location#{type => array, value => NewValue};
        false ->
            concat_error(lists:reverse(Acc), Location)
    end;
do_concat([], Location, Acc) when length(Acc) > 1 ->
    concat_error(lists:reverse(Acc), Location);
do_concat([], _, [Acc]) ->
    Acc;

do_concat([#{type := array}=A | More], Location, Acc) ->
    do_concat(More, Location, [A#{value => lists:map(fun verify_concat/1, value_of(A))} | Acc]);
do_concat([#{type := object}=O | More], Location, Acc) ->
    ConcatO = lists:map(fun verify_concat/1, value_of(O)),
    do_concat(More, Location, lists:reverse(ConcatO, Acc));
do_concat([#{type:= string}=S | More], Location, Acc) ->
    do_concat(More, Location, [S | Acc]);
do_concat([#{type := concat}=C | More], Location, Acc) ->
    ConcatC = do_concat(value_of(C), #{line => line_of(C), filename => filename_of(C)}),
    do_concat([ConcatC | More], Location, Acc);
do_concat([{#{type := key}=K, Value} | More], Location, Acc) ->
    do_concat(More, Location, [{K, verify_concat(Value)} | Acc]);
do_concat([Other | More], Location, Acc) ->
    do_concat(More, Location, [Other | Acc]).

-spec(transform(hocon_token:boxed()) -> config()).
transform(#{type := object}=O) ->
    do_transform(remove_nothing(value_of(O)), #{}).

do_transform([], Map) -> Map;
do_transform([{Key, Value} | More], Map) ->
    do_transform(More, merge(hd(paths(hocon_token:value_of(Key))), unpack(Value), Map)).

unpack(#{type := object}=O) ->
    do_transform(remove_nothing(value_of(O)), #{});
unpack(#{type := array}=A) ->
    [unpack(Val) || Val <- remove_nothing(value_of(A))];
unpack(Literal) -> value_of(Literal).

remove_nothing(List) ->
    lists:filter(fun (nothing) -> false;
                     ({_Key, nothing}) -> false;
                     (_Other) -> true end, List).

paths(Key) when is_atom(Key) ->
    paths(atom_to_list(Key));
paths(Key) when is_list(Key) ->
    lists:map(fun list_to_atom/1, string:tokens(Key, ".")).

merge(Key, Val, Map) when is_map(Val) ->
    case maps:find(Key, Map) of
        {ok, MVal} when is_map(MVal) ->
            maps:put(Key, hocon_util:do_deep_merge(MVal, Val), Map);
        _Other -> maps:put(Key, Val, Map)
    end;
merge(Key, Val, Map) -> maps:put(Key, Val, Map).

resolve_error(Unresolved) ->
    NFL = fun (V) ->
        case filename_of(V) of
            undefined ->
                io_lib:format(", ~p at_line ~p", [name_of(V), line_of(V)]) ;
            F ->
                io_lib:format(", ~p in_file ~p at_line ~p", [name_of(V), F, line_of(V)]) end
        end,
    <<_LeadingComma, Enriched/binary>> = lists:foldl(fun (V, AccIn) ->
         iolist_to_binary([AccIn, NFL(V)]) end, "", Unresolved),
    throw({resolve_error, iolist_to_binary(["failed_to_resolve", Enriched])}).

concat_error(Acc, Location) ->
    ErrorInfo = case filename_of(Location) of
        undefined ->
            io_lib:format("failed_to_concat ~p at_line ~p",
                          [format_tokens(Acc), line_of(Location)]);
        F ->
            io_lib:format("failed_to_concat ~p in_file ~p at_line ~p",
                          [format_tokens(Acc), F, line_of(Location)])
        end,
    throw({concat_error, iolist_to_binary(ErrorInfo)}).

% transforms tokens to values.
format_tokens(List) when is_list(List) ->
    lists:map(fun format_tokens/1, List);
format_tokens(#{type := array}=A) ->
    lists:map(fun format_tokens/1, value_of(A));
format_tokens({K, V}) ->
    {format_tokens(K), format_tokens(V)};
format_tokens(Token) ->
    hocon_token:value_of(Token).

value_of(Token) ->
    hocon_token:value_of(Token).

line_of(#{line := Line}) ->
    Line;
line_of(_Other) ->
    undefined.

type_of(#{type := Type}) ->
    Type;
type_of(_Other) ->
    undefined.

filename_of(#{filename := Filename}) ->
    Filename;
filename_of(_Other) ->
    undefined.

name_of(#{type := variable, name := N}) ->
    N.

duration(X) ->
    hocon_postprocess:duration(X).
