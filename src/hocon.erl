%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-export([scan/2, parse/2, dump/2, dump/3]).
-export([main/1]).

-type config() :: map().
-type ctx() :: #{path => list(),
                 filename => list()}.
-type convert() :: duration | bytesize | percent | onoff | convert_func().
-type convert_func() :: fun((term()) -> term()).
-type opts() :: #{format => map | proplists,
                  convert => [convert()]}.

-export_type([config/0]).

-define(SECOND, 1000).
-define(MINUTE, (?SECOND*60)).
-define(HOUR,   (?MINUTE*60)).
-define(DAY,    (?HOUR*24)).

-define(KILOBYTE, 1024).
-define(MEGABYTE, (?KILOBYTE*1024)). %1048576
-define(GIGABYTE, (?MEGABYTE*1024)). %1073741824

main(Args) ->
    hocon_cli:main(Args).

proplists(Map) when is_map(Map) ->
    proplists(maps:iterator(Map), [], []).
proplists(Iter, Path, Acc) ->
    case maps:next(Iter) of
        {K, M, I} when is_map(M) ->
            Child = proplists(maps:iterator(M), [atom_to_list(K)| Path], []),
            proplists(I, Path, lists:append(Child, Acc));
        {K, [Bin|_More]=L, I} when is_binary(Bin) ->
            NewList = [binary_to_list(B) || B <- L],
            ReversedPath = lists:reverse([atom_to_list(K)| Path]),
            proplists(I, Path, [{ReversedPath, NewList}| Acc]);
        {K, Bin, I} when is_binary(Bin) ->
            ReversedPath = lists:reverse([atom_to_list(K)| Path]),
            proplists(I, Path, [{ReversedPath, binary_to_list(Bin)}| Acc]);
        {K, V, I} ->
            ReversedPath = lists:reverse([atom_to_list(K)| Path]),
            proplists(I, Path, [{ReversedPath, V}| Acc]);
        none ->
            Acc
    end.

convert_value(ConvertFunctions, Map) when is_list(ConvertFunctions) ->
    Resolved = resolve_convert_fun(ConvertFunctions),
    do_convert_value(pipeline_fun(Resolved), Map).

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

-spec(load(file:filename()) -> {ok, config()} | {error, term()}).
load(Filename0) ->
    load(Filename0, #{format => map}).

-spec(load(file:filename(), opts()) -> {ok, config()} | {error, term()}).
load(Filename0, Opts) ->
    Filename = filename:absname(Filename0),
    Ctx = stack_multiple_push([{path, '$root'}, {filename, Filename}], #{}),
    try
        Bytes = read(Filename),
        Map = do_binary(Bytes, Ctx),
        {ok, apply_opts(Map, Opts)}
    catch
        throw:Reason -> {error, Reason}
    end.

apply_opts(Map, Opts) ->
    ConvertedMap = case maps:find(convert, Opts) of
        {ok, Converter} ->
            convert_value(Converter, Map);
        _ ->
            Map
    end,
    case maps:find(format, Opts) of
        {ok, proplists} ->
            proplists(ConvertedMap);
        _ ->
            ConvertedMap
    end.

%% @doc Load a file and return a parsed key-value list.
%% Because this function is intended to be called by include/2,
%% variable substitution is not performed here.
%% @end
load_include(Filename0, Ctx0) ->
    Cwd = filename:dirname(hd(get_stack(filename, Ctx0))),
    Filename = filename:join([Cwd, Filename0]),
    case is_included(Filename, Ctx0) of
        true ->
            throw({cycle, get_stack(filename, Ctx0)});
        false ->
            Ctx = stack_push({filename, Filename}, Ctx0),
            pipeline(Filename, Ctx,
                     [ fun read/1
                     , fun scan/2
                     , fun trans_key/1
                     , fun parse/2
                     , fun include/2
                     ])
    end.

binary(Binary) ->
    try
        {ok, do_binary(Binary, #{})}
    catch
        throw:Reason -> {error, Reason}
    end.

do_binary(Binary, Ctx) ->
    pipeline(Binary, Ctx,
             [ fun scan/2
             , fun trans_key/1
             , fun parse/2
             , fun include/2
             , fun expand/1
             , fun resolve/1
             , fun remove_nothing/1
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

-spec read(file:filename()) -> binary().
read(Filename) ->
    case file:read_file(Filename) of
        {ok, <<239, 187, 191, Rest/binary>>} ->
            %% Ignore BOM header
            Rest;
        {ok, Bytes} ->
            Bytes;
        {error, Reason} ->
            throw({Reason, Filename})
    end.

-spec scan(binary()|string(), ctx()) -> list().
scan(Input, Ctx) when is_binary(Input) ->
    scan(binary_to_list(Input), Ctx);
scan(Input, Ctx) when is_list(Input) ->
    case hocon_scanner:string(Input) of
        {ok, Tokens, _EndLine} ->
            Tokens;
        {error, {Line, _Mod, ErrorInfo}, _} ->
            scan_error(Line, hocon_scanner:format_error(ErrorInfo), Ctx)
    end.

parse([], _) -> [];
parse(Tokens, Ctx) ->
    case hocon_parser:parse(Tokens) of
        {ok, Ret} -> Ret;
        {error, {Line, _Module, ErrorInfo}} ->
            parse_error(Line, ErrorInfo, Ctx)
    end.

-spec include(list(), ctx()) -> list().
include(KVList, Ctx) ->
    do_include(KVList, [], Ctx, get_stack(path, Ctx)).

do_include([], Acc, _Ctx, _CurrentPath) ->
    lists:reverse(Acc);
do_include([{'$include', Filename}|More], Acc, Ctx, CurrentPath) ->
    Parsed = load_include(Filename, Ctx#{path := CurrentPath}),
    do_include(More, lists:reverse(Parsed, Acc), Ctx, CurrentPath);
do_include([{var, Var}|More], Acc, Ctx, CurrentPath) ->
    VarWithAbsPath = abspath(Var, get_stack(path, Ctx)),
    do_include(More, [{var, VarWithAbsPath}|Acc], Ctx, CurrentPath);
do_include([{Key, {concat, MaybeObject}}|More], Acc, Ctx, CurrentPath) ->
    NewPath = [Key|CurrentPath],
    do_include(More,
               [{Key, {concat, do_include(MaybeObject, [], Ctx, NewPath)}}|Acc],
               Ctx,
               CurrentPath);
do_include([{Object}|More], Acc, Ctx, CurrentPath) when is_list(Object) ->
    do_include(More, [{do_include(Object, [], Ctx, CurrentPath)}|Acc], Ctx, CurrentPath);
do_include([Other|More], Acc, Ctx, CurrentPath) ->
    do_include(More, [Other|Acc], Ctx, CurrentPath).

abspath({maybe, Var}, PathStack) ->
    {maybe, do_abspath(atom_to_binary(Var, utf8), PathStack)};
abspath(Var, PathStack) ->
    do_abspath(atom_to_binary(Var, utf8), PathStack).

do_abspath(Var, []) ->
    binary_to_atom(Var, utf8);
do_abspath(Var, ['$root']) ->
    binary_to_atom(Var, utf8);
do_abspath(Var, [Path|More]) ->
    do_abspath(iolist_to_binary([atom_to_binary(Path, utf8), <<".">>, Var]), More).

expand(KVList) ->
    do_expand(KVList, []).

do_expand([], Acc) ->
    lists:reverse(Acc);
do_expand([{Key, {concat, C}}|More], Acc) ->
    do_expand(More, [create_nested(Key, {concat, do_expand(C, [])})|Acc]);
do_expand([{Key, Value}|More], Acc) ->
    do_expand(More, [create_nested(Key, Value)|Acc]);
do_expand([{Object}|More], Acc) when is_list(Object) ->
    do_expand(More, [{do_expand(Object, [])}|Acc]);
do_expand([Other|More], Acc) ->
    do_expand(More, [Other|Acc]).

create_nested(Key, Value) when is_atom(Key) ->
    {concat, [{[Res]}]} = do_create_nested(paths(Key), Value),
    Res.

do_create_nested([], Value) ->
    Value;
do_create_nested([Path|More], Value) ->
    {concat, [{[{Path, do_create_nested(More, Value)}]}]}.

resolve(KVList) ->
    case do_resolve(KVList, [], [], KVList) of
        skip ->
            KVList;
        {resolved, Resolved} ->
            resolve(Resolved);
        {unresolved, Unresolved} ->
            throw({unresolved, lists:flatten(Unresolved)})
    end.
do_resolve([], _Acc, [], _RootKVList) ->
    skip;
do_resolve([], _Acc, Unresolved, _RootKVList) ->
    {unresolved, Unresolved};
do_resolve([V|More], Acc, Unresolved, RootKVList) ->
    case do_resolve(V, [], [], RootKVList) of
        {resolved, Resolved} ->
            {resolved, lists:reverse(Acc, [Resolved|More])};
        {unresolved, Var} ->
            do_resolve(More, [V| Acc], [Var| Unresolved], RootKVList);
        skip ->
            do_resolve(More, [V| Acc], Unresolved, RootKVList);
        delete ->
            {resolved, lists:reverse(Acc, [nothing|More])}
    end;
do_resolve({concat, List}, _Acc, _Unresolved, RootKVList) when is_list(List) ->
    case do_resolve(List, [], [], RootKVList) of
        {resolved, Resolved} ->
            {resolved, {concat, Resolved}};
        {unresolved, Var} ->
            {unresolved, Var};
        skip ->
            skip
    end;
do_resolve({var, {maybe, Var}}, _Acc, _Unresolved, RootKVList) ->
    case lookup(paths(Var), RootKVList) of
        notfound ->
            delete;
        ResolvedValue ->
            {resolved, ResolvedValue}
    end;
do_resolve({var, Var}, _Acc, _Unresolved, RootKVList) ->
    case lookup(paths(Var), RootKVList) of
        notfound ->
            {unresolved, Var};
        ResolvedValue ->
            {resolved, ResolvedValue}
    end;
do_resolve({Object}, _Acc, _Unresolved, RootKVList) when is_list(Object) ->
    case do_resolve(Object, [], [], RootKVList) of
        {resolved, Resolved} ->
            {resolved, {Resolved}};
        {unresolved, Var} ->
            {unresolved, Var};
        skip ->
            skip
    end;
do_resolve({Key, Value}, _Acc, _Unresolved, RootKVList) ->
    case do_resolve(Value, [], [], RootKVList) of
        {resolved, Resolved} ->
            {resolved, {Key, Resolved}};
        {unresolved, Var} ->
            {unresolved, Var};
        skip ->
            skip;
        delete ->
            delete
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

lookup(Var, KVList) ->
    lookup(Var, KVList, notfound).

lookup(Var, {concat, List}, ResolvedValue) ->
    lookup(Var, List, ResolvedValue);
lookup([Var], [{Var, Value} = KV|More], ResolvedValue) ->
    case is_resolved(KV) of
        true ->
            lookup([Var], More, Value);
        false ->
            lookup([Var], More, ResolvedValue)
    end;
lookup([Path|MorePath] = Var, [{Path, Value}|More], ResolvedValue) ->
    lookup(Var, More, lookup(MorePath, Value, ResolvedValue));
lookup(Var, [{List}|More], ResolvedValue) ->
    lookup(Var, More, lookup(Var, List, ResolvedValue));
lookup(Var, [_Other|More], ResolvedValue) ->
    lookup(Var, More, ResolvedValue);
lookup(_Var, [], ResolvedValue) ->
    ResolvedValue.

remove_nothing(List) ->
    remove_nothing(List, []).

remove_nothing([], Acc) ->
    lists:reverse(Acc);
remove_nothing([{Key, {concat, Concat}}|More], Acc) ->
    % if the value of an object field is an unresolved maybevar
    % then the field should not be created.
    case do_remove_nothing(Concat) of
        [] ->
            remove_nothing(More, Acc);
        Removed ->
            remove_nothing(More, [{Key, {concat, Removed}}|Acc])
    end;
remove_nothing([{concat, Concat}|More], Acc) ->
    case do_remove_nothing(Concat) of
        [] ->
            remove_nothing(More, Acc);
        Removed ->
            remove_nothing(More, [{concat, Removed}|Acc])
    end;
remove_nothing([Other|More], Acc) ->
    remove_nothing(More, [Other|Acc]).

do_remove_nothing(Concat) ->
    do_remove_nothing(Concat, []).
do_remove_nothing([], Acc) ->
    lists:reverse(Acc);
do_remove_nothing([{concat, Concat}| More], Acc) ->
    case do_remove_nothing(Concat) of
        [] ->
            do_remove_nothing(More, Acc);
        Removed ->
            do_remove_nothing(More, [{concat, Removed}|Acc])
    end;
do_remove_nothing([nothing| More], Acc) ->
    % unresolved maybevar disappears silently.
    % if it is part of a value concatenation with another string,
    % then it should become an empty string
    do_remove_nothing(More, Acc);
do_remove_nothing([Array| More], Acc) when is_list(Array) ->
    % if one of the elements is unresolved maybevar,
    % then the element should not be added.
    do_remove_nothing(More, [remove_nothing(Array)| Acc]);
do_remove_nothing([{Object}| More], Acc) when is_list(Object) ->
    % if all fields are found to be nothing,
    % create empty object
    case remove_nothing(Object) of
        [] ->
            do_remove_nothing(More, [{}| Acc]);
        Removed ->
            do_remove_nothing(More, [{Removed}| Acc])
    end;
do_remove_nothing([Other| More], Acc) ->
    do_remove_nothing(More, [Other| Acc]).



-spec concat(list()) -> list().
concat(List) ->
    lists:map(fun (E) -> verify_concat(E) end, List).

verify_concat({concat, Concat}) ->
    do_concat(Concat);
verify_concat({Key, Value}) ->
    {Key, verify_concat(Value)};
verify_concat(Other) ->
    Other.

do_concat(Concat) ->
    do_concat(Concat, []).

% empty object ( a={} )
do_concat([], [{}]) ->
    {[]};
do_concat([], [Object| _Objects] = Acc) when is_tuple(Object) ->
    {lists:reverse(Acc)};
do_concat([], [String| _Strings] = Acc) when is_binary(String) ->
    iolist_to_binary(lists:reverse(Acc));
do_concat([], [Array| _Arrays] = Acc) when is_list(Array) ->
    lists:append(lists:reverse(Acc));
do_concat([], [Acc]) ->
    Acc;
do_concat([], Acc) ->
    lists:reverse(Acc);

do_concat([Array| More], Acc) when is_list(Array) ->
    do_concat(More, [concat(Array)| Acc]);
do_concat([{Object}| More], Acc)  when is_list(Object) ->
    do_concat(More, lists:foldl(fun(KV, A) -> [verify_concat(KV)| A] end, Acc, Object));
do_concat([String| More], Acc)  when is_binary(String) ->
    do_concat(More, [String| Acc]);
do_concat([{concat, Concat}|More], Acc) ->
    do_concat([do_concat(Concat)|More], Acc);
do_concat([Other|More], Acc) ->
    do_concat(More, [Other|Acc]).

transform({Members}) ->
    transform(Members);
transform(Members) when is_list(Members) ->
    do_transform(Members, #{}).

do_transform([], Map) -> Map;
do_transform([{Key, Value}| More], Map) ->
    do_transform(More, nested_put(paths(Key), unpack(Value), Map)).

unpack({Members}) ->
    transform(Members);
unpack(Array) when is_list(Array) ->
    [unpack(Val) || Val <- Array];
unpack(Literal) -> Literal.

paths(Key) when is_atom(Key) ->
    paths(atom_to_list(Key));
paths(Key) when is_binary(Key) ->
    paths(binary_to_list(Key));
paths(Key) when is_list(Key) ->
    lists:map(fun list_to_atom/1, string:tokens(Key, ".")).

nested_put([Key], Val, Map) ->
    merge(Key, Val, Map);
nested_put([Key|Paths], Val, Map) ->
    merge(Key, nested_put(Paths, Val, #{}), Map).

merge(Key, Val, Map) when is_map(Val) ->
    case maps:find(Key, Map) of
        {ok, MVal} when is_map(MVal) ->
            maps:put(Key, do_deep_merge(MVal, Val), Map);
        _Other -> maps:put(Key, Val, Map)
    end;
merge(Key, Val, Map) -> maps:put(Key, Val, Map).

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

scan_error(Line, ErrorInfo, Ctx) ->
    throw({scan_error, format_error(Line, ErrorInfo, Ctx)}).

parse_error(Line, ErrorInfo, Ctx) ->
    throw({parse_error, format_error(Line, ErrorInfo, Ctx)}).

format_error(Line, ErrorInfo, Ctx) ->
    binary_to_list(
        iolist_to_binary(
            [ErrorInfo,
             io_lib:format(" in line ~w. file: ~p", [Line, hd(get_stack(filename, Ctx))])])).

stack_multiple_push(List, Ctx) ->
    lists:foldl(fun stack_push/2, Ctx, List).

stack_push({Key, Value}, Ctx) ->
    Stack = get_stack(Key, Ctx),
    Ctx#{Key => [Value | Stack]}.

is_included(Filename, Ctx) ->
    Includes = get_stack(filename, Ctx),
    lists:any(fun(F) -> is_same_file(F, Filename) end, Includes).

get_stack(Key, Ctx) -> maps:get(Key, Ctx, []).

is_same_file(A, B) ->
    real_file_name(A) =:= real_file_name(B).

real_file_name(F) ->
    case file:read_link_all(F) of
        {ok, Real} -> Real;
        {error, _} -> F
    end.

%% Due to the lack of a splicable value terminal token,
%% the parser would have to look-ahead the second token
%% to tell if the next token is another splicable (string)
%% or a key (which is also string).
%%
%% This help function is to 'look-back' from the key-value separator
%% tokens, namingly ':', '=' and '{', then tranform the proceeding
%% string token to a 'key' token.
%%
%% In the second step, it 'look-ahead' for a the last string/variable
%% token preceeding to a non-string/variable token and transform
%% it to a 'endstr' or 'endvar' token.
trans_key(Tokens) ->
    trans_splice_end(trans_key(Tokens, [])).

trans_key([], Acc) -> lists:reverse(Acc);
trans_key([{T, _Line} | Tokens], Acc) when T =:= ':' orelse
                                           T =:= '=' ->
    %% ':' and '=' are not pushed back
    trans_key(Tokens, trans_key_lb(Acc));
trans_key([{'{', Line} | Tokens], Acc) ->
    %% '{' is pushed back
    trans_key(Tokens, [{'{', Line} | trans_key_lb(Acc)]);
trans_key([T | Tokens], Acc) ->
    trans_key(Tokens, [T | Acc]).

trans_key_lb([{string, Line, Value} | TokensRev]) ->
    [{key, Line, binary_to_atom(Value, utf8)} | TokensRev];
trans_key_lb(Otherwise) -> Otherwise.

trans_splice_end(Tokens) ->
    trans_splice_end(Tokens, [], []).

trans_splice_end([{key, _Line, _Value} = V | Tokens], Seq, Acc) ->
    NewAcc = [V | do_trans_splice_end(Seq) ++ Acc],
    trans_splice_end(Tokens, [], NewAcc);
trans_splice_end([{include, _File} = V | Tokens], Seq, Acc) ->
    NewAcc = [V | do_trans_splice_end(Seq) ++ Acc],
    trans_splice_end(Tokens, [], NewAcc);
trans_splice_end([{T, _Line} = V | Tokens], Seq, Acc)  when T =:= ',' ->
    NewAcc = [V | do_trans_splice_end(Seq) ++ Acc],
    trans_splice_end(Tokens, [], NewAcc);
trans_splice_end([{T, _Line} = V | Tokens], Seq, Acc)  when T =:= '}' orelse
                                                            T =:= ']' ->
    NewAcc = do_trans_splice_end(Seq) ++ Acc,
    trans_splice_end(Tokens, [V], NewAcc);
trans_splice_end([V | Tokens], Seq, Acc) ->
    trans_splice_end(Tokens, [V | Seq], Acc);
trans_splice_end([], Seq, Acc) ->
    NewAcc = do_trans_splice_end(Seq) ++ Acc,
    lists:reverse(NewAcc).

do_trans_splice_end([]) -> [];
do_trans_splice_end([{string, Line, Value} | T]) ->
    [{endstr, Line, Value} | T];
do_trans_splice_end([{variable, Line, Value} | T]) ->
    [{endvar, Line, Value} | T];
do_trans_splice_end([{'}', Line} | T]) ->
    [{endobj, Line} | T];
do_trans_splice_end([{']', Line} | T]) ->
    [{endarr, Line} | T];
do_trans_splice_end(Other) ->
    Other.

onoff(Bin) when is_binary(Bin) ->
    case do_onoff(binary_to_list(Bin)) of
        Bool when Bool =:= true orelse Bool =:= false ->
            Bool;
        Str when is_list(Str) ->
            list_to_binary(Str)
    end;
onoff(Other) ->
    Other.
do_onoff("on")  -> true;
do_onoff("off") -> false;
do_onoff(X) -> X.

re_run_first(Str, MP) ->
    re:run(Str, MP, [{capture, all_but_first, list}]).

percent(Bin) when is_binary(Bin) ->
    case do_percent(binary_to_list(Bin)) of
        Percent when is_float(Percent) ->
            Percent;
        Str when is_list(Str) ->
            list_to_binary(Str)
    end;
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
    case do_bytesize(binary_to_list(Bin)) of
        Byte when is_integer(Byte) ->
            Byte;
        Str when is_list(Str) ->
            list_to_binary(Str)
    end;
bytesize(Other) ->
    Other.
do_bytesize(Str) ->
    {ok, MP} = re:compile("([0-9]+)(kb|KB|mb|MB|gb|GB)$"),
    case re_run_first(Str, MP) of
        {match, [Val, Unit]} ->
            do_bytesize(list_to_integer(Val), Unit);
        _ -> Str
    end.
do_bytesize(Val, "kb") -> Val * ?KILOBYTE;
do_bytesize(Val, "KB") -> Val * ?KILOBYTE;
do_bytesize(Val, "mb") -> Val * ?MEGABYTE;
do_bytesize(Val, "MB") -> Val * ?MEGABYTE;
do_bytesize(Val, "gb") -> Val * ?GIGABYTE;
do_bytesize(Val, "GB") -> Val * ?GIGABYTE.

duration(Bin) when is_binary(Bin) ->
    case do_duration(binary_to_list(Bin)) of
        Duration when is_integer(Duration) ->
            Duration;
        Str when is_list(Str) ->
            list_to_binary(Str)
    end;
duration(Other) ->
    Other.
do_duration(Str) ->
    {ok, MP} = re:compile("([0-9]+)(d|D|h|H|m|M|s|S|ms|MS)$"),
    case re:run(string:to_lower(Str), MP, [{capture, all_but_first, list}]) of
        {match, [Val, Unit]} ->
            do_duration(list_to_integer(Val), Unit);
        _ -> Str
    end.
do_duration(Val, "d")  -> Val * ?DAY;
do_duration(Val, "h")  -> Val * ?HOUR;
do_duration(Val, "m")  -> Val * ?MINUTE;
do_duration(Val, "s")  -> Val * ?SECOND;
do_duration(Val, "ms") -> Val.
