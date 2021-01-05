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
-export([scan/1, parse/1, dump/2, dump/3]).
-export([main/1]).

-type config() :: map().
-type ctx() :: map().

-export_type([config/0]).

main(Args) ->
    hocon_cli:main(Args).

-spec(load(file:filename()) -> {ok, config()} | {error, term()}).
load(Filename) ->
    load(Filename, #{}).

load(Filename0, Ctx0) ->
    Filename = filename:absname(Filename0),
    Ctx = inc_stack_multiple_push([{path, '$root'}, {filename, Filename}], Ctx0),
    pipeline(Filename, Ctx,
             [ fun read/1
             , fun scan/1
             , fun preparse/1
             , fun parse/1
             , fun include/2
             , fun resolve/1
             , fun concat/1
             , fun expand/1
             ]).

load_include(Filename0, Ctx0) ->
    Cwd = filename:dirname(hd(inc_stack(filename, Ctx0))),
    Filename = filename:join([Cwd, Filename0]),
    case is_included(Filename, Ctx0) of
        true ->
            {error, {cycle, inc_stack(filename, Ctx0)}};
        false ->
            Ctx = inc_stack_push({filename, Filename}, Ctx0),
            pipeline(Filename, Ctx,
                     [ fun read/1
                     , fun scan/1
                     , fun preparse/1
                     , fun parse/1
                     , fun include/2
                     ])
    end.

binary(Binary) ->
    pipeline(Binary, #{},
             [ fun scan/1
             , fun preparse/1
             , fun parse/1
             , fun include/2
             , fun resolve/1
             , fun concat/1
             , fun expand/1
             ]).

dump(Config, App) ->
    [{App, to_list(Config)}].

dump(Config, App, Filename) ->
    file:write_file(Filename, io_lib:fwrite("~p.\n", [dump(Config, App)])).

to_list(Config) when is_map(Config) ->
    maps:to_list(maps:map(fun(_Key, MVal) -> to_list(MVal) end, Config));
to_list(Value) -> Value.

-spec(read(file:filename()) -> {ok, binary()} | {error, term()}).
read(Filename) ->
    case file:read_file(Filename) of
        {ok, <<239, 187, 191, Rest/binary>>} ->
            %% Ignore BOM header
            {ok, Rest};
        {ok, Bytes} ->
            {ok, Bytes};
        {error, enoent} ->
            error({enoent, Filename})
    end.

-spec(scan(binary()|string()) -> {ok, config()} | {error, Reason}
     when Reason :: {scan_error, string()}).
scan(Input) when is_binary(Input) ->
    scan(binary_to_list(Input));
scan(Input) when is_list(Input) ->
    case hocon_scanner:string(Input) of
        {ok, Tokens, _EndLine} -> {ok, Tokens};
        {error, {Line, _Mod, ErrorInfo}, _} ->
            scan_error(Line, hocon_scanner:format_error(ErrorInfo))
    end.


-spec preparse(list()) -> {ok, list()} | {error, any()}.
preparse(Tokens) ->
    try
        {ok, trans_key(Tokens)}
    catch
        error:Reason:St -> {error, {Reason,St}}
    end.

-spec(parse(list()) -> {ok, config()} | {error, Reason}
      when Reason :: {parse_error, string()}).
parse([]) -> {ok, []};
parse(Tokens) ->
    case hocon_parser:parse(Tokens) of
        {ok, Ret} -> {ok, Ret};
        {error, {Line, _Module, ErrorInfo}} ->
            parse_error(Line, ErrorInfo)
    end.

-spec include(list(), ctx()) -> {ok, list()} | {error, any()}.
include(KVList, Ctx) ->
    try
        {ok, do_include(KVList, Ctx)}
    catch
        error:Reason -> {error, Reason}
    end.

do_include(KVList, Ctx) ->
    try
        do_include(KVList, [], Ctx, inc_stack(path, Ctx))
    catch
        error:Reason -> error(Reason)
    end.

do_include([], Acc, _Ctx, _CurrentPath) ->
    lists:reverse(Acc);
do_include([{'$include', Filename}|More], Acc, Ctx, CurrentPath) ->
    case load_include(Filename, Ctx#{path := CurrentPath}) of
        {ok, Parsed} -> do_include(More, unpack_kvlist(Parsed, Acc), Ctx, CurrentPath);
        {error, Reason} -> error(Reason)
    end;
do_include([{[{'$include', Filename}]}|More], Acc, Ctx, CurrentPath) ->
    case load_include(Filename, Ctx#{path := CurrentPath}) of
        {ok, Parsed} -> do_include(More, [{Parsed}|Acc], Ctx, CurrentPath);
        {error, Reason} -> error(Reason)
    end;
do_include([{var, Var}|More], Acc, Ctx, _CurrentPath) ->
    VarWithAbsPath = abspath(Var, inc_stack(path, Ctx)),
    do_include(More, [{var, VarWithAbsPath}|Acc], Ctx, _CurrentPath);
do_include([{Key, {concat, MaybeObject}}|More], Acc, Ctx, CurrentPath) ->
    NewPath = [Key|CurrentPath],
    do_include(More, [{Key, {concat, do_include(MaybeObject, [], Ctx, NewPath)}}|Acc], Ctx, CurrentPath);
do_include([{Object}|More], Acc, Ctx, CurrentPath) when is_list(Object) ->
    do_include(More, [{do_include(Object, [], Ctx, CurrentPath)}|Acc], Ctx, CurrentPath);
do_include([Other|More], Acc, Ctx, CurrentPath) ->
    do_include(More, [Other|Acc], Ctx, CurrentPath).

abspath(Var, PathStack) ->
    do_abspath(atom_to_binary(Var, utf8), PathStack).

do_abspath(Var, []) ->
    binary_to_atom(Var, utf8);
do_abspath(Var, ['$root']) ->
    binary_to_atom(Var, utf8);
do_abspath(Var, [Path|More]) ->
    do_abspath(iolist_to_binary([atom_to_binary(Path, utf8), <<".">>, Var]), More).

unpack_kvlist(KVList, AccIn) ->
    lists:foldl(fun (Elem, A) -> [Elem|A] end, AccIn, KVList).

-spec resolve(list()) -> {ok, list()} | {error, any()}.
resolve(KVList) ->
    try
        {ok, do_resolve(KVList)}
    catch
        error:Reason:St -> {error, {Reason,St}}
    end.

do_resolve(KVList) ->
    case do_resolve(KVList, [], [], KVList) of
        skip ->
            KVList;
        {resolved, Resolved} ->
            do_resolve(Resolved);
        {unresolved, Unresolved} ->
            error({unresolved, lists:flatten(Unresolved)})
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
            do_resolve(More, [V| Acc], Unresolved, RootKVList)
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

-spec concat(list()) -> {ok, list()} | {error, any()}.
concat(List) ->
    try
        {ok, iter_over_list_for_concat(List)}
    catch
        error:Reason:St -> {error, {Reason,St}}
    end.

iter_over_list_for_concat(List) when is_list(List) ->
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
    do_concat(More, [iter_over_list_for_concat(Array)| Acc]);
do_concat([{Object}| More], Acc)  when is_list(Object) ->
    do_concat(More, lists:foldl(fun(KV, A) -> [verify_concat(KV)| A] end, Acc, Object));
do_concat([String| More], Acc)  when is_binary(String) ->
    do_concat(More, [String| Acc]);
do_concat([{concat, Concat}|More], Acc) ->
    do_concat([do_concat(Concat)|More], Acc);
do_concat([Other|More], Acc) ->
    do_concat(More, [Other|Acc]).

expand({Members}) ->
    expand(Members);
expand(Members) when is_list(Members) ->
    expand(Members, #{}).

expand([], Map) -> Map;
expand([{Key, Value}|More], Map) ->
    expand(More, nested_put(paths(Key), expand_value(Value), Map)).

expand_value({Members}) ->
    expand(Members);
expand_value(Array) when is_list(Array) ->
    [expand_value(Val) || Val <- Array];
expand_value(Literal) -> Literal.

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

pipeline(Input, Ctx, [Fun | Steps]) ->
    Result = case is_function(Fun, 1) of
                 true -> Fun(Input);
                 false -> Fun(Input, Ctx)
             end,
    case Result of
        {ok, Output} -> pipeline(Output, Ctx, Steps);
        {error, Reason} -> {error, Reason};
        Output -> pipeline(Output, Ctx, Steps)
    end;
pipeline(Output, _Ctx, []) -> {ok, Output}.

scan_error(Line, ErrorInfo) ->
    {error, {scan_error, format_error(Line, ErrorInfo)}}.

parse_error(Line, ErrorInfo) ->
    {error, {parse_error, format_error(Line, ErrorInfo)}}.

format_error(Line, ErrorInfo) ->
    binary_to_list(
      iolist_to_binary(
        [ErrorInfo, io_lib:format(" in line ~w", [Line])])).

inc_stack_multiple_push(List, Ctx) ->
    lists:foldl(fun inc_stack_push/2, Ctx, List).

inc_stack_push({Key, Value}, Ctx) ->
    Stack = inc_stack(Key, Ctx),
    Ctx#{Key => [Value | Stack]}.

is_included(Filename, Ctx) ->
    Includes = inc_stack(filename, Ctx),
    lists:any(fun(F) -> is_same_file(F, Filename) end, Includes).

inc_stack(Key, Ctx) -> maps:get(Key, Ctx, []).

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
