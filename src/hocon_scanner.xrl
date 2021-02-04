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

%% -*- erlang -*-

Definitions.

%% Unicode  |  Name                |  Escape Char
%% -------- | -------------------- | -----------------
%% \x{0008}	|  backspace           |  \b
%% \x{0009}	|  tab                 |  \t
%% \x{000A}	|  line feed           |  \n
%% \x{000B}	|  line-tab            |
%% \x{000C}	|  form feed           |  \f
%% \x{000D}	|  carriage-return     |  \r
%% \x{0020}	|  space               |  \s
%% \x{00A0}	|  non-break space     |  ??
%% \x{2028}	|  line seperator      |
%% \x{2029}	|  paragraph separator |

%% Whitespace, Comments and Line Feed
WhiteSpace          = [\x{0009}\x{000B}\x{000C}\x{0020}\x{00A0}]
LineFeed            = \x{000A}\x{000D}\x{2028}\x{2029}
NewLine             = [{LineFeed}]
Comment             = (#|//)[^{LineFeed}]*
Ignored             = {WhiteSpace}|{NewLine}|{Comment}

%% Punctuator
Punctuator          = [{}\[\],:=]
TrailingComma       = ,({Ignored})*}|,({Ignored})*]

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
Escape              = ["\\\/bfnrt]
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
{TrailingComma}   : {skip_token, string:trim(TokenChars, leading, ",")}.
{Bool}            : {token, {bool, TokenLine, bool(TokenChars)}}.
{Null}            : {token, {null, TokenLine, null}}.
{Unquoted}        : {token, maybe_include(TokenChars, TokenLine)}.
{Integer}         : {token, {integer, TokenLine, list_to_integer(TokenChars)}}.
{Float}           : {token, {float, TokenLine, to_float(TokenChars)}}.
{String}          : {token, {string, TokenLine, iolist_to_binary(unquote(TokenChars))}}.
{MultilineString} : {token, {string, TokenLine, iolist_to_binary(unquote(TokenChars))}}.
{Bytesize}        : {token, {string, TokenLine, iolist_to_binary(TokenChars)}}.
{Percent}         : {token, {string, TokenLine, iolist_to_binary(TokenChars)}}.
{Duration}        : {token, {string, TokenLine, iolist_to_binary(TokenChars)}}.
{Variable}        : {token, {variable, TokenLine, var_ref_name(TokenChars)}}.
{MaybeVar}        : {token, {variable, TokenLine, {maybe, maybe_var_ref_name(TokenChars)}}}.
{Required}        : {token, {required, TokenLine}, get_filename_from_required(TokenChars)}.


Erlang code.

maybe_include("include", TokenLine)  -> {include, TokenLine};
maybe_include(TokenChars, TokenLine) -> {string, TokenLine, iolist_to_binary(TokenChars)}.

get_filename_from_required("required(" ++ Filename) ->
    [$) | FilenameRev] = lists:reverse(Filename),
    string:trim(lists:reverse(FilenameRev)).

bool("true")  -> true;
bool("false") -> false.

unquote(Str) -> string:strip(Str, both, $").

maybe_var_ref_name("${?" ++ Name_CR) ->
    [$} | NameRev] = lists:reverse(Name_CR),
    list_to_atom(string:trim(lists:reverse(NameRev))).

var_ref_name("${" ++ Name_CR) ->
    [$} | NameRev] = lists:reverse(Name_CR),
    list_to_atom(string:trim(lists:reverse(NameRev))).

to_float("." ++ Fraction) -> to_float("0." ++ Fraction);
to_float(Str) -> list_to_float(Str).
