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

-module(hocon_token).

-export([read/1, scan/2, trans_key/1, parse/2, include/2]).
-export([value_of/1]).

-export_type([boxed/0, inbox/0]).

-type boxed() :: #{type := hocon_type(),
                   value := inbox(),
                   line => integer(),
                   filename => string(),
                   required => boolean()}.
-type inbox() :: primitive() | [{Key :: boxed(), boxed()}] | [boxed()].
-type primitive() :: null | boolean() | number() | binary().
-type hocon_type() :: null | bool | integer | float
                    | string | array | object | hocon_intermediate_type().
-type hocon_intermediate_type() :: variable | include | concat. %% to be reduced

-include("hocon.hrl").

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

-spec scan(binary() | string(), hocon:ctx()) -> list().
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

parse([], _) -> #{type => object, value => []};
parse(Tokens, Ctx) ->
    case hocon_parser:parse(Tokens) of
        {ok, Ret} -> Ret;
        {error, {Line, _Module, ErrorInfo}} ->
            parse_error(Line, ErrorInfo, Ctx)
    end.

-spec include(boxed(), hocon:ctx()) -> boxed().
include(#{type := object}=O, Ctx) ->
    hocon_util:do_deep_merge(O, #{value => do_include(value_of(O), [], Ctx, hocon_util:get_stack(path, Ctx)),
                                  metadata => #{filename => hd(hocon_util:get_stack(filename, Ctx))}}).

do_include([], Acc, _Ctx, _CurrentPath) ->
    lists:reverse(Acc);

do_include([#{type := include}=Include | More], Acc, Ctx, CurrentPath) ->
    case load_include(Include, Ctx#{path := CurrentPath}) of
        nothing ->
            do_include(More, Acc, Ctx, CurrentPath);
        #{type := object}=O ->
            do_include(More, lists:reverse(value_of(O), Acc), Ctx, CurrentPath)
    end;
do_include([#{type := variable}=V | More], Acc, Ctx, CurrentPath) ->
    VarWithAbsPath = abspath(value_of(V), hocon_util:get_stack(path, Ctx)),
    NewV = hocon_util:do_deep_merge(V, #{metadata => #{filename => filename(Ctx)},
                                         value => VarWithAbsPath}),
    do_include(More, [NewV | Acc], Ctx, CurrentPath);
do_include([{Key, #{type := T}=X} | More], Acc, Ctx, CurrentPath) when ?IS_VALUE_LIST(T) ->
    NewKey = hocon_util:do_deep_merge(Key, #{metadata => #{filename => filename(Ctx)}}),
    NewValue = do_include(value_of(X), [], Ctx, [Key | CurrentPath]),
    NewX = hocon_util:do_deep_merge(X, #{metadata => #{filename => filename(Ctx), line => line_of(Key)},
                                         value => NewValue}),
    do_include(More, [{NewKey, NewX} | Acc], Ctx, CurrentPath);
do_include([#{type := T}=X | More], Acc, Ctx, CurrentPath) when ?IS_VALUE_LIST(T) ->
    NewValue = do_include(value_of(X), [], Ctx, CurrentPath),
    do_include(More, [hocon_util:do_deep_merge(X, #{metadata => #{filename => filename(Ctx)},
                                                    value => NewValue}) | Acc], Ctx, CurrentPath);
do_include([{Key, #{type := _T}=X} | More], Acc, Ctx, CurrentPath) ->
    NewKey = hocon_util:do_deep_merge(Key, #{metadata => #{filename => filename(Ctx)}}),
    NewX = hocon_util:do_deep_merge(X, #{metadata => #{filename => filename(Ctx),
                                                       line => line_of(Key)}}),
    do_include(More, [{NewKey, NewX} | Acc], Ctx, CurrentPath);
do_include([#{type := _T}=X | More], Acc, Ctx, CurrentPath) ->
    NewX = hocon_util:do_deep_merge(X, #{metadata => #{filename => filename(Ctx)}}),
    do_include(More, [NewX | Acc], Ctx, CurrentPath).

filename(Ctx) ->
    hocon_util:top_stack(filename, Ctx).

abspath(Var, PathStack) ->
    do_abspath(atom_to_binary(Var, utf8), PathStack).

do_abspath(Var, ['$root']) ->
    binary_to_atom(Var, utf8);
do_abspath(Var, [#{type := key}=K | More]) ->
    do_abspath(iolist_to_binary([atom_to_binary(value_of(K), utf8), <<".">>, Var]), More).


-spec load_include(boxed(), hocon:ctx()) -> boxed() | nothing.

%% @doc Load a file and return a parsed key-value list.
%% Because this function is intended to be called by include/2,
%% variable substitution is not performed here.
%% @end
load_include(#{type := include, value := Value, required := Required}, Ctx0) ->
    Cwd = filename:dirname(hd(hocon_util:get_stack(filename, Ctx0))),
    Filename = binary_to_list(filename:join([Cwd, Value])),
    case {file:read_file_info(Filename), Required} of
        {{error, enoent}, true} ->
            throw({enoent, Filename});
        {{error, enoent}, false} ->
            nothing;
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
                                , fun parse/2
                                , fun include/2
                                ])
    end
    end.

is_included(Filename, Ctx) ->
    Includes = hocon_util:get_stack(filename, Ctx),
    lists:any(fun(F) -> hocon_util:is_same_file(F, Filename) end, Includes).

value_of(#{value := V}) -> V.
line_of(#{metadata := #{line := L}}) -> L.

scan_error(Line, ErrorInfo, Ctx) ->
    throw({scan_error, format_error(Line, ErrorInfo, Ctx)}).

parse_error(Line, ErrorInfo, Ctx) ->
    throw({parse_error, format_error(Line, ErrorInfo, Ctx)}).

format_error(Line, ErrorInfo, #{filename := [undefined]}) ->
    iolist_to_binary(
            [ErrorInfo,
             io_lib:format(" at_line ~w.",
                           [Line])]);
format_error(Line, ErrorInfo, Ctx) ->
    iolist_to_binary(
        [ErrorInfo,
         io_lib:format(" in_file ~p at_line ~w.",
                       [hd(hocon_util:get_stack(filename, Ctx)), Line])]).
