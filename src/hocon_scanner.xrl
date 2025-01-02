%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% -*- erlang -*-

Definitions.

%% Whitespace, Comments and Line Feed
WhiteSpace          = [\x{0009}\x{000B}\x{000C}\x{0020}\x{00A0}]
LineFeed            = \x{000A}\x{000D}\x{2028}\x{2029}
NewLine             = [{LineFeed}]
Comment             = (#|//)[^{LineFeed}]*
Ignored             = {WhiteSpace}|{NewLine}|{Comment}

%% Punctuator
Punctuator          = [{}\[\],:=]

%% Null
Null               = null

%% Unquoted String
Letter              = [A-Za-z]
Unquoted            = {Letter}[A-Za-z0-9_\.@%\-\|]*

%% Bool
Bool                = true|false

%% Integer
Digit               = [0-9]
Sign                = [+\-]
Integer             = {Sign}?({Digit}+)

%% Float
Fraction            = \.{Digit}+
Exponent            = [eE]{Sign}?{Digit}+
Float               = {Integer}?{Fraction}|{Integer}{Fraction}{Exponent}

%% String
Hex                 = [0-9A-Fa-f]
Escape              = ["\\bfnrt]
UnicodeEscape       = u{Hex}{Hex}{Hex}{Hex}
Char                = ([^\"{LineFeed}]|\\{Escape}|\\{UnicodeEscape})
String              = "{Char}*"
MultilineChar       = ([^"]|"[^"]|""[^"]|\\{Escape}|\\{UnicodeEscape})
MultilineString     = """{MultilineChar}*"""

%% Bytesize and Duration
Percent             = {Digit}+%
Bytesize            = {Digit}+(kb|KB|mb|MB|gb|GB)
Duration            = {Digit}+(d|D|h|H|m|M|s|S|ms|MS)
%%Duration            = {Digit}+(d|h|m|s|ms|us|ns)

%% Variable
Literal             = {Bool}|{Integer}|{Float}|{String}|{Unquoted}|{Percent}{Bytesize}|{Duration}
Variable            = \$\{{Unquoted}\}
MaybeVar            = \$\{\?{Unquoted}\}

%% Include
Required            = (required)\({String}\)

Rules.

{Ignored}         : skip_token.
{Punctuator}      : {token, {list_to_atom(string:trim(TokenChars)), TokenLine}}.
{Bool}            : {token, {bool, TokenLine, bool(TokenChars)}}.
{Null}            : {token, {null, TokenLine, null}}.
{Unquoted}        : {token, maybe_include(TokenChars, TokenLine)}.
{Integer}         : {token, {integer, TokenLine, list_to_integer(TokenChars)}}.
{Float}           : {token, {float, TokenLine, to_float(TokenChars)}}.
{String}          : {token, {string, TokenLine, unquote(TokenChars, force_escape)}}.
{MultilineString} : {token, {string, TokenLine, unindent(strip_quotes(TokenChars, 3, TokenLine))}}.
{Bytesize}        : {token, {string, TokenLine, TokenChars}}.
{Percent}         : {token, {string, TokenLine, TokenChars}}.
{Duration}        : {token, {string, TokenLine, TokenChars}}.
{Variable}        : {token, {variable, TokenLine, var_ref_name(TokenChars)}}.
{MaybeVar}        : {token, {variable, TokenLine, {'maybe', maybe_var_ref_name(TokenChars)}}}.
{Required}        : {token, {required, TokenLine}, get_filename_from_required(TokenChars)}.


Erlang code.

-export([unindent/1]).

maybe_include("include", TokenLine)  -> {include, TokenLine};
maybe_include(TokenChars, TokenLine) -> {unqstr, TokenLine, TokenChars}.

get_filename_from_required("required(" ++ Filename) ->
    [$) | FilenameRev] = lists:reverse(Filename),
    string:trim(lists:reverse(FilenameRev)).

bool("true")  -> true;
bool("false") -> false.

unquote([$\" | Str0], Allow) ->
    [$\" | StrR] = lists:reverse(Str0),
    unescape(lists:reverse(StrR), Allow).

%% strip the given number of quotes from both ends of the string.
strip_quotes(Str, N, Line) ->
    Str1 = strip_quotes_loop(Str, N),
    case strip_quotes_loop(lists:reverse(Str1), N) of
        [$\", $\\ | _] ->
            throw({scan_error, #{reason => four_closing_quotes, line => Line}});
        StrR ->
            lists:reverse(StrR)
    end.

%% strip the leading quotes and return the remaining chars
strip_quotes_loop([$" | Rem], N) when N > 0 ->
    strip_quotes_loop(Rem, N - 1);
strip_quotes_loop(Str, _) ->
    Str.

unindent([$~, $\r, $\n | Chars]) ->
    do_unindent(Chars);
unindent([$~, $\n | Chars]) ->
    do_unindent(Chars);
unindent(Chars) ->
    Chars.

do_unindent(Chars) ->
    Lines = split_lines(Chars),
    Indent = min_indent(Lines),
    NewLines = lists:map(fun(Line) -> trim_indents(Line, Indent) end, Lines),
    lists:flatten(lists:join($\n, NewLines)).

split_lines(Chars) ->
    split_lines(Chars, "", []).

%% Split multiline strings like
%% """~
%%    line1
%%    line2
%% ~"""
%% into ["line1\n", "line2\n"]
split_lines([], LastLineR, Lines) ->
    %% if the last line ends with '~' drop it
    LastLine = case LastLineR of
        [$~ | Rest] ->
            lists:reverse(Rest);
        _ ->
            lists:reverse(LastLineR)
    end,
    lists:reverse([LastLine | Lines]);
split_lines([$\n | Chars], Line, Lines) ->
    split_lines(Chars, [], [lists:reverse(Line) | Lines]);
split_lines([Char | Chars], Line, Lines) ->
    split_lines(Chars, [Char | Line], Lines).

min_indent([LastLine]) ->
    case indent_level(LastLine) of
        ignore ->
            0;
        Indent ->
            Indent
    end;
min_indent(Lines0) ->
    [LastLine | Lines] = lists:reverse(Lines0),
    LastLineIndent = indent_level(LastLine),
    Indents0 = lists:map(fun indent_level/1, Lines),
    MinIndent = case lists:filter(fun erlang:is_integer/1, Indents0) of
        [] ->
            0;
        Indents ->
            lists:min(Indents)
    end,
    %% If last line is all space, use the minimum indent of the preceding lines,
    %% because the last line is allowed to indent less than other lines.
    case LastLine =/= [] andalso lists:all(fun(I) -> I =:= $\s end, LastLine) of
        true ->
            MinIndent;
        false ->
            min(LastLineIndent, MinIndent)
    end.

indent_level([]) ->
    ignore;
indent_level([$\r]) ->
    ignore;
indent_level(Line) ->
    indent_level(Line, 0).

indent_level([$\s | Chars], Count) ->
    indent_level(Chars, Count + 1);
indent_level(_, Count) ->
    Count.

trim_indents([], _Indent) ->
    [];
trim_indents([$\r], _Indent) ->
    [$\r];
trim_indents(Chars, 0) ->
    Chars;
trim_indents([$\s | Chars], Indent) when Indent > 0 ->
    trim_indents(Chars, Indent - 1).

% the first clause is commented out on purpose
% meaning below two escape sequence (in a hocon file)
% key="\\""
% key="\\\""
% would be parsed into the same vaulue a string
% of two chars, a back-slash and a double-quote
% this is left as it is to keep backward compatibility.
%unescape([$" | _], force_escape) ->
%    throw(unescaped_quote);
unescape([], _Allow) ->
    [];
unescape(S, Allow) ->
    {H, T} = unesc(S),
    [H | unescape(T, Allow)].

unesc([$\\, $\\ | T]) -> {$\\, T};
unesc([$\\, $" | T]) -> {$", T};
unesc([$\\, $n | T]) -> {$\n, T};
unesc([$\\, $t | T]) -> {$\t, T};
unesc([$\\, $r | T]) -> {$\r, T};
unesc([$\\, $b | T]) -> {$\b, T};
unesc([$\\, $f | T]) -> {$\f, T};
unesc([H | T]) -> {H, T}.

maybe_var_ref_name("${?" ++ Name_CR) ->
    [$} | NameRev] = lists:reverse(Name_CR),
    unicode:characters_to_binary(string:trim(lists:reverse(NameRev)), utf8).

var_ref_name("${" ++ Name_CR) ->
    [$} | NameRev] = lists:reverse(Name_CR),
    unicode:characters_to_binary(string:trim(lists:reverse(NameRev)), utf8).

to_float("." ++ Fraction) -> to_float("0." ++ Fraction);
to_float(Str) -> list_to_float(Str).
