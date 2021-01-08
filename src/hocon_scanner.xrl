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
Bool                = true|false|on|off

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

Rules.

{Ignored}         : skip_token.
{Punctuator}      : {token, {list_to_atom(string:trim(TokenChars)), TokenLine}}.
{TrailingComma}   : {skip_token, string:trim(TokenChars, leading, ",")}.
{Bool}            : {token, {bool, TokenLine, bool(TokenChars)}}.
{Null}            : {token, {null, TokenLine}}.
{Unquoted}        : {token, maybe_include(TokenChars, TokenLine)}.
{Integer}         : {token, {integer, TokenLine, list_to_integer(TokenChars)}}.
{Float}           : {token, {float, TokenLine, to_float(TokenChars)}}.
{String}          : {token, {string, TokenLine, iolist_to_binary(unquote(TokenChars))}}.
{MultilineString} : {token, {string, TokenLine, iolist_to_binary(unquote(TokenChars))}}.
{Bytesize}        : {token, {bytesize, TokenLine, bytesize(TokenChars)}}.
{Percent}         : {token, {percent, TokenLine, percent(TokenChars)}}.
{Duration}        : {token, {duration, TokenLine, duration(TokenChars)}}.
{Variable}        : {token, {variable, TokenLine, {var, var_ref_name(TokenChars)}}}.
{MaybeVar}        : {token, {variable, TokenLine, {var, {maybe, maybe_var_ref_name(TokenChars)}}}}.


Erlang code.

-define(SECOND, 1000).
-define(MINUTE, (?SECOND*60)).
-define(HOUR,   (?MINUTE*60)).
-define(DAY,    (?HOUR*24)).

-define(KILOBYTE, 1024).
-define(MEGABYTE, (?KILOBYTE*1024)). %1048576
-define(GIGABYTE, (?MEGABYTE*1024)). %1073741824

maybe_include("include", TokenLine)  -> {include, TokenLine};
maybe_include(TokenChars, TokenLine) -> {string, TokenLine, iolist_to_binary(TokenChars)}.

bool("true")  -> true;
bool("false") -> false;
bool("on")    -> true;
bool("off")   -> false.

unquote(Str) -> string:strip(Str, both, $").

percent(Str) ->
    list_to_integer(string:strip(Str, right, $%)) / 100.

bytesize(Str) ->
    {ok, MP} = re:compile("([0-9]+)(kb|KB|mb|MB|gb|GB)"),
    {match, [Val,Unit]} = re:run(Str, MP, [{capture, all_but_first, list}]),
    bytesize(list_to_integer(Val), Unit).

bytesize(Val, "kb") -> Val * ?KILOBYTE;
bytesize(Val, "KB") -> Val * ?KILOBYTE;
bytesize(Val, "mb") -> Val * ?MEGABYTE;
bytesize(Val, "MB") -> Val * ?MEGABYTE;
bytesize(Val, "gb") -> Val * ?GIGABYTE;
bytesize(Val, "GB") -> Val * ?GIGABYTE.

duration(Str) ->
    {ok, MP} = re:compile("([0-9]+)(d|D|h|H|m|M|s|S|ms|MS)"),
    {match, [Val,Unit]} = re:run(string:to_lower(Str), MP, [{capture, all_but_first, list}]),
    duration(list_to_integer(Val), Unit).

duration(Val, "d")  -> Val * ?DAY;
duration(Val, "h")  -> Val * ?HOUR;
duration(Val, "m")  -> Val * ?MINUTE;
duration(Val, "s")  -> Val * ?SECOND;
duration(Val, "ms") -> Val.

maybe_var_ref_name("${?" ++ Name_CR) ->
    [$} | NameRev] = lists:reverse(Name_CR),
    list_to_atom(string:trim(lists:reverse(NameRev))).

var_ref_name("${" ++ Name_CR) ->
    [$} | NameRev] = lists:reverse(Name_CR),
    list_to_atom(string:trim(lists:reverse(NameRev))).

to_float("." ++ Fraction) -> to_float("0." ++ Fraction);
to_float(Str) -> list_to_float(Str).