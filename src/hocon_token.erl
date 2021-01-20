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

-module(hocon_token).

-export([read/1, scan/2, trans_key/1, detect_forbidden_whitespace/2, parse/2, include/2]).

-type include() :: #{filename => binary(), required => boolean()}.

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

-spec scan(binary()|string(), hocon:ctx()) -> list().
scan(Input, Ctx) when is_binary(Input) ->
    scan(binary_to_list(Input), Ctx);
scan(Input, Ctx) when is_list(Input) ->
    case hocon_scanner:string(Input) of
        {ok, Tokens, _EndLine} ->
            Tokens;
        {error, {Line, _Mod, ErrorInfo}, _} ->
            scan_error(Line, hocon_scanner:format_error(ErrorInfo), Ctx)
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
trans_key_lb([{unquoted, Line, Value} | TokensRev]) ->
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
do_trans_splice_end([{unquoted, Line, Value} | T]) ->
    [{endunq, Line, Value} | T];
do_trans_splice_end([{variable, Line, Value} | T]) ->
    [{endvar, Line, Value} | T];
do_trans_splice_end([{'}', Line} | T]) ->
    [{endobj, Line} | T];
do_trans_splice_end([{']', Line} | T]) ->
    [{endarr, Line} | T];
do_trans_splice_end(Other) ->
    Other.

-spec detect_forbidden_whitespace(list(), hocon:ctx()) -> list().
detect_forbidden_whitespace(Tokens, Ctx) ->
    detect_forbidden_whitespace(Tokens, [], Ctx).
detect_forbidden_whitespace([], Acc, _Ctx) ->
    lists:reverse(Acc);
detect_forbidden_whitespace([{unquoted, Line, V2} | _T], [{unquoted, _, V1} | _Acc], Ctx) ->
    whitespace_error(Line, {V1, V2}, Ctx);
detect_forbidden_whitespace([{endunq, Line, V2} | _T], [{unquoted, _, V1} | _Acc], Ctx) ->
    whitespace_error(Line, {V1, V2}, Ctx);
detect_forbidden_whitespace([Other|T], Acc, Ctx) ->
    detect_forbidden_whitespace(T, [Other|Acc], Ctx).


parse([], _) -> [];
parse(Tokens, Ctx) ->
    case hocon_parser:parse(Tokens) of
        {ok, Ret} -> Ret;
        {error, {Line, _Module, ErrorInfo}} ->
            parse_error(Line, ErrorInfo, Ctx)
    end.

-spec include(list(), hocon:ctx()) -> list().
include(KVList, Ctx) ->
    do_include(KVList, [], Ctx, hocon_util:get_stack(path, Ctx)).

do_include([], Acc, _Ctx, _CurrentPath) ->
    lists:reverse(Acc);
do_include([{'$include', Include}|More], Acc, Ctx, CurrentPath) ->
    Parsed = load_include(Include, Ctx#{path := CurrentPath}),
    do_include(More, lists:reverse(Parsed, Acc), Ctx, CurrentPath);
do_include([{var, Var}|More], Acc, Ctx, CurrentPath) ->
    VarWithAbsPath = abspath(Var, hocon_util:get_stack(path, Ctx)),
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


-spec load_include(include(), hocon:ctx()) -> list().

%% @doc Load a file and return a parsed key-value list.
%% Because this function is intended to be called by include/2,
%% variable substitution is not performed here.
%% @end
load_include(Include, Ctx0) ->
    Cwd = filename:dirname(hd(hocon_util:get_stack(filename, Ctx0))),
    Filename = filename:join([Cwd, maps:get(filename, Include)]),
    case {file:read_file_info(Filename), maps:get(required, Include, false)} of
        {{error, enoent}, true} ->
            throw({enoent, Filename});
        {{error, enoent}, false} ->
            % empty kvlist
            [];
        _ ->
    case is_included(Filename, Ctx0) of
        true ->
            throw({cycle, hocon_util:get_stack(filename, Ctx0)});
        false ->
            Ctx = hocon_util:stack_push({filename, Filename}, Ctx0),
            hocon_util:pipeline(Filename, Ctx,
                                [ fun read/1
                                , fun scan/2
                                , fun trans_key/1
                                , fun detect_forbidden_whitespace/2
                                , fun parse/2
                                , fun include/2
                                ])
    end
    end.

is_included(Filename, Ctx) ->
    Includes = hocon_util:get_stack(filename, Ctx),
    lists:any(fun(F) -> is_same_file(F, Filename) end, Includes).

is_same_file(A, B) ->
    real_file_name(A) =:= real_file_name(B).

real_file_name(F) ->
    case file:read_link_all(F) of
        {ok, Real} -> Real;
        {error, _} -> F
    end.

scan_error(Line, ErrorInfo, Ctx) ->
    throw({scan_error, format_error(Line, ErrorInfo, Ctx)}).

whitespace_error(Line, {V1, V2}, Ctx) ->
    ErrorInfo = "unquoted string contains whitespace between "
             ++ binary_to_list(V1) ++ " and " ++ binary_to_list(V2),
    throw({whitespace_error, format_error(Line, ErrorInfo, Ctx)}).

parse_error(Line, ErrorInfo, Ctx) ->
    throw({parse_error, format_error(Line, ErrorInfo, Ctx)}).

format_error(Line, ErrorInfo, Ctx) ->
    case hocon_util:get_stack(filename, Ctx) of
        [] ->
            binary_to_list(
                iolist_to_binary(
                    [ErrorInfo,
                     io_lib:format(" in line ~w.", [Line])]));
        File ->
            binary_to_list(
                iolist_to_binary(
                    [ErrorInfo,
                     io_lib:format(" in line ~w. file: ~p",
                                   [Line, hd(File)])]))
    end.
