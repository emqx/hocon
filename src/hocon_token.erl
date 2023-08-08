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

-module(hocon_token).

-export([read/1, scan/2, trans_key/1, rm_trailing_comma/1, parse/2, include/2]).
-export([value_of/1]).

-export_type([boxed/0, inbox/0]).

-include("hocon.hrl").
-include("hocon_private.hrl").

-type boxed() :: #{
    ?HOCON_T := hocon_type(),
    ?HOCON_V := inbox(),
    ?METADATA := map(),
    required => boolean()
}.
-type inbox() :: primitive() | [{Key :: boxed(), boxed()}] | [boxed()].
-type primitive() :: null | boolean() | number() | binary().
-type hocon_type() ::
    null
    | bool
    | integer
    | float
    | string
    | array
    | object
    | hocon_intermediate_type().
%% to be reduced
-type hocon_intermediate_type() :: variable | include | concat.

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
    case unicode_list(Input) of
        {error, _Ok, Invalid} ->
            throw({scan_invalid_utf8, Invalid, Ctx});
        InputList ->
            scan(InputList, Ctx)
    end;
scan(Input, Ctx) when is_list(Input) ->
    case hocon_scanner:string(Input) of
        {ok, Tokens, _EndLine} ->
            Tokens;
        {error, {Line, _Mod, ErrorInfo}, _} ->
            scan_error(Line, hocon_scanner:format_error(ErrorInfo), Ctx)
    end.

rm_trailing_comma(Tokens) ->
    rm_trailing_comma(Tokens, []).

rm_trailing_comma([], Acc) -> lists:reverse(Acc);
rm_trailing_comma([{',', _}, {'}', _} = Cr | More], Acc) -> rm_trailing_comma(More, [Cr | Acc]);
rm_trailing_comma([{',', _}, {']', _} = Sr | More], Acc) -> rm_trailing_comma(More, [Sr | Acc]);
rm_trailing_comma([Other | More], Acc) -> rm_trailing_comma(More, [Other | Acc]).

%% Due to the lack of a splicable value terminal token,
%% the parser would have to look-ahead the second token
%% to tell if the next token is another splicable (string)
%% or a key (which is also string).
%%
%% This help function is to 'look-back' from the key-value separator
%% tokens, namingly ':', '=' and '{', then transform the proceeding
%% string token to a 'key' token.
%%
%% In the second step, it 'look-ahead' for a the last string/variable
%% token preceding to a non-string/variable token and transform
%% it to a 'endstr' or 'endvar' token.
trans_key(Tokens) ->
    trans_splice_end(trans_key(Tokens, [])).

trans_key([], Acc) ->
    lists:reverse(Acc);
trans_key([{T, _Line} | Tokens], Acc) when
    T =:= ':' orelse
        T =:= '='
->
    %% ':' and '=' are not pushed back
    trans_key(Tokens, trans_key_lb(Acc));
trans_key([{'{', Line} | Tokens], Acc) ->
    %% '{' is pushed back
    trans_key(Tokens, [{'{', Line} | trans_key_lb(Acc)]);
trans_key([T | Tokens], Acc) ->
    trans_key(Tokens, [T | Acc]).

trans_key_lb([{string, Line, Value} | TokensRev]) ->
    [{key, Line, {quoted, Value}} | TokensRev];
trans_key_lb([{unquoted_string, Line, Value} | TokensRev]) ->
    [{key, Line, Value} | TokensRev];
trans_key_lb(Otherwise) ->
    Otherwise.

trans_splice_end(Tokens) ->
    trans_splice_end(Tokens, [], []).

trans_splice_end([{key, _Line, _Value} = V | Tokens], Seq, Acc) ->
    NewAcc = [V | do_trans_splice_end(Seq) ++ Acc],
    trans_splice_end(Tokens, [], NewAcc);
trans_splice_end([{include, _File} = V | Tokens], Seq, Acc) ->
    NewAcc = [V | do_trans_splice_end(Seq) ++ Acc],
    trans_splice_end(Tokens, [], NewAcc);
trans_splice_end([{T, _Line} = V | Tokens], Seq, Acc) when T =:= ',' ->
    NewAcc = [V | do_trans_splice_end(Seq) ++ Acc],
    trans_splice_end(Tokens, [], NewAcc);
trans_splice_end([{'}', Line1} = V1, {'{', Line2} = V2 | Tokens], Seq, Acc) when
    Line1 /= Line2
->
    %% Inject virtual comma to avoid concatenating objects that are separated by newlines,
    %% as we don't track newline tokens here.
    trans_splice_end([V1, {',', Line1}, V2 | Tokens], Seq, Acc);
trans_splice_end([{T, _Line} = V | Tokens], Seq, Acc) when
    T =:= '}' orelse
        T =:= ']'
->
    NewAcc = do_trans_splice_end(Seq) ++ Acc,
    trans_splice_end(Tokens, [V], NewAcc);
trans_splice_end([V | Tokens], Seq, Acc) ->
    trans_splice_end(Tokens, [V | Seq], Acc);
trans_splice_end([], Seq, Acc) ->
    NewAcc = do_trans_splice_end(Seq) ++ Acc,
    lists:reverse(NewAcc).

do_trans_splice_end([]) -> [];
do_trans_splice_end([{string, Line, Value} | T]) -> [{endstr, Line, Value} | T];
do_trans_splice_end([{unquoted_string, Line, Value} | T]) -> [{endstr, Line, Value} | T];
do_trans_splice_end([{variable, Line, Value} | T]) -> [{endvar, Line, Value} | T];
do_trans_splice_end([{'}', Line} | T]) -> [{endobj, Line} | T];
do_trans_splice_end([{']', Line} | T]) -> [{endarr, Line} | T];
do_trans_splice_end(Other) -> Other.

parse([], _) ->
    #{?HOCON_T => object, ?HOCON_V => []};
parse(Tokens, Ctx) ->
    case hocon_parser:parse(Tokens) of
        {ok, Ret} -> Ret;
        {error, {Line, _Module, ErrorInfo}} -> parse_error(Line, ErrorInfo, Ctx)
    end.

-spec include(boxed(), hocon:ctx()) -> boxed().
include(#{?HOCON_T := object} = O, Ctx) ->
    NewV = do_include(value_of(O), [], Ctx, hocon_util:get_stack(path, Ctx)),
    Filename = hd(hocon_util:get_stack(filename, Ctx)),
    hocon_maps:deep_merge(O, box_v(Filename, NewV)).

do_include([], Acc, _Ctx, _CurrentPath) ->
    lists:reverse(Acc);
do_include([#{?HOCON_T := include} = Include | More], Acc, Ctx, CurrentPath) ->
    case load_include(Include, Ctx#{path := CurrentPath}) of
        nothing ->
            do_include(More, Acc, Ctx, CurrentPath);
        #{?HOCON_T := object} = O ->
            do_include(More, lists:reverse(value_of(O), Acc), Ctx, CurrentPath)
    end;
do_include([#{?HOCON_T := variable} = V | More], Acc, Ctx, CurrentPath) ->
    VarWithAbsPath = abspath(value_of(V), hocon_util:get_stack(path, Ctx)),
    NewV = hocon_maps:deep_merge(V, box_v(filename(Ctx), VarWithAbsPath)),
    do_include(More, [NewV | Acc], Ctx, CurrentPath);
do_include([{Key, #{?HOCON_T := T} = X} | More], Acc, Ctx, CurrentPath) when ?IS_VALUE_LIST(T) ->
    NewKey = hocon_maps:deep_merge(Key, box(filename(Ctx))),
    NewValue = do_include(value_of(X), [], Ctx, [Key | CurrentPath]),
    NewX = hocon_maps:deep_merge(X, box_v(filename(Ctx), line_of(Key), NewValue)),
    do_include(More, [{NewKey, NewX} | Acc], Ctx, CurrentPath);
do_include([#{?HOCON_T := T} = X | More], Acc, Ctx, CurrentPath) when ?IS_VALUE_LIST(T) ->
    NewValue = do_include(value_of(X), [], Ctx, CurrentPath),
    do_include(
        More,
        [hocon_maps:deep_merge(X, box_v(filename(Ctx), NewValue)) | Acc],
        Ctx,
        CurrentPath
    );
do_include([{Key, #{?HOCON_T := _T} = X} | More], Acc, Ctx, CurrentPath) ->
    NewKey = hocon_maps:deep_merge(Key, box(filename(Ctx))),
    NewX = hocon_maps:deep_merge(X, box(filename(Ctx), line_of(Key))),
    do_include(More, [{NewKey, NewX} | Acc], Ctx, CurrentPath);
do_include([#{?HOCON_T := _T} = X | More], Acc, Ctx, CurrentPath) ->
    NewX = hocon_maps:deep_merge(X, box(filename(Ctx))),
    do_include(More, [NewX | Acc], Ctx, CurrentPath).

box_v(Filename, Value) ->
    box_v(Filename, _Line = undefined, Value).

box_v(Filename, Line, Value) ->
    Box = box(Filename, Line),
    Box#{?HOCON_V => Value}.

box(Filename) ->
    mk_box([{filename, Filename}]).

box(Filename, Line) ->
    mk_box([{filename, Filename}, {line, Line}]).

mk_box(MetaFields) ->
    Meta = maps:from_list(lists:filter(fun({_, V}) -> V =/= undefined end, MetaFields)),
    #{?METADATA => Meta}.

filename(Ctx) ->
    hocon_util:top_stack(filename, Ctx).

abspath(Var, PathStack) ->
    do_abspath(Var, PathStack).

do_abspath(Var, ['$root']) ->
    Var;
do_abspath(Var, [#{?HOCON_T := key} = K | More]) ->
    do_abspath(unicode_bin([value_of(K), <<".">>, Var]), More).

-spec load_include(boxed(), hocon:ctx()) -> boxed() | nothing.

%% @doc Load a file and return a parsed key-value list.
%% Because this function is intended to be called by include/2,
%% variable substitution is not performed here.
%% @end
load_include(#{?HOCON_T := include, ?HOCON_V := Value, required := Required}, Ctx0) ->
    Cwd = filename:dirname(hd(hocon_util:get_stack(filename, Ctx0))),
    IncludeDirs = hd(hocon_util:get_stack(include_dirs, Ctx0)),
    case search_file([Cwd | IncludeDirs], Value) of
        {ok, Filename} ->
            case is_included(Filename, Ctx0) of
                true ->
                    throw({cycle, hocon_util:get_stack(filename, Ctx0)});
                false ->
                    Ctx = hocon_util:stack_push({filename, Filename}, Ctx0),
                    hocon_util:pipeline(
                        Filename,
                        Ctx,
                        [
                            fun read/1,
                            fun scan/2,
                            fun trans_key/1,
                            fun parse/2,
                            fun include/2
                        ]
                    )
            end;
        {error, enoent} when Required -> throw({enoent, Value});
        {error, enoent} ->
            nothing;
        {error, Errors} ->
            throw(Errors)
    end.

search_file(Dirs, File) -> search_file(Dirs, File, []).

search_file([], _File, []) ->
    {error, enoent};
search_file([], _File, Reasons) ->
    {error, Reasons};
search_file([Dir | Dirs], File, Reasons0) ->
    Filename = unicode_list(filename:join([Dir, File])),
    case file:read_file_info(Filename) of
        {ok, _} ->
            {ok, Filename};
        {error, enoent} ->
            search_file(Dirs, File, Reasons0);
        {error, Reason} ->
            Reasons = [{Reason, Filename} | Reasons0],
            search_file(Dirs, File, Reasons)
    end.

is_included(Filename, Ctx) ->
    Includes = hocon_util:get_stack(filename, Ctx),
    lists:any(fun(F) -> hocon_util:is_same_file(F, Filename) end, Includes).

value_of(#{?HOCON_V := V}) -> V.

line_of(#{?METADATA := #{line := L}}) -> L.

scan_error(Line, ErrorInfo, Ctx) ->
    throw({scan_error, format_error(Line, ErrorInfo, Ctx)}).

parse_error(Line, ErrorInfo, Ctx) ->
    throw({parse_error, format_error(Line, ErrorInfo, Ctx)}).

format_error(Line, ErrorInfo, #{filename := [undefined]}) ->
    #{
        reason => lists:flatten([ErrorInfo]),
        line => Line
    };
format_error(Line, ErrorInfo, Ctx) ->
    #{
        reason => lists:flatten([ErrorInfo]),
        line => Line,
        file => hd(hocon_util:get_stack(filename, Ctx))
    }.

unicode_bin(L) -> unicode:characters_to_binary(L, utf8).
unicode_list(B) -> unicode:characters_to_list(B, utf8).
