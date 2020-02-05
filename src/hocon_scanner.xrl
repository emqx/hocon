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
%% \x{000A}	|  newline             |  \n
%% \x{000D}	|  carriage-return     |  \r
%% \x{0009}	|  tab                 |  \t
%% \x{0020}	|  space               |  \s
%% \x{0009}	|  backspace           |  \b
%% \x{00A0}	|  non-break space     |  ??
%% \x{000C}	|  form feed           |  \f
%% \x{000B}	|  line-tab            |
%% \x{2028}	|  line seperator      |
%% \x{2029}	|  paragraph separator |

%% Whitespace, Comments and Line Seperator
WhiteSpace          = [\x{0009}\x{000B}\x{000C}\x{0020}\x{00A0}]
LineSeperator       = \x{000A}\x{000D}\x{2028}\x{2029}
Comment             = (#|//)[^{LineSeperator}]*

%% Bool
Bool                = true|false|on|off

%% Name(Atom in Erlang)
Letter              = [A-Za-z]
Name                = {Letter}({Letter}|{Digit}|[_\.@])*

%% Integer
Digit               = [0-9]
Sign                = [+\-]
Integer             = {Sign}?({Digit}+)

%% Float
Fraction            = \.{Digit}+
Exponent            = [eE]{Sign}?{Digit}+
Float               = {Integer}{Fraction}|{Integer}{Fraction}{Exponent}

%% String
Hex                 = [0-9A-Fa-f]
Escape              = ["\\\/bfnrt]
UnicodeEscape       = u{Hex}{Hex}{Hex}{Hex}
Character           = ([^\"{LineSeperator}]|\\{Escape}|\\{UnicodeEscape})
String              = "{Character}*"
MultilineCharacter  = ([^"]|"[^"]|""[^"]|\\{Escape}|\\{UnicodeEscape})
MultilineString     = """{MultilineCharacter}*"""

%% Bytesize and Duration
Bytesize            = {Digit}+(KB|MB|GB)
Duration            = {Digit}+(d|h|m|s|ms|us|ns)

%% TODO: Env

Rules.

{WhiteSpace}+     : skip_token.
{Comment}         : skip_token.
{Bool}            : {token, {bool, TokenLine, bool(TokenChars)}}.
{Name}            : {token, identifier(TokenChars, TokenLine)}.
{Integer}         : {token, {integer, TokenLine, list_to_integer(TokenChars)}}.
{Float}           : {token, {float, TokenLine, list_to_float(TokenChars)}}.
{String}          : {token, {string, TokenLine, iolist_to_binary(unquote(TokenChars))}}.
{MultilineString} : {token, {string, TokenLine, iolist_to_binary(unquote(TokenChars))}}.
{Bytesize}        : {token, {bytesize, TokenLine, TokenChars}}.
{Duration}        : {token, {duration, TokenLine, TokenChars}}.

{   : {token, {'{', TokenLine}}.
}   : {token, {'}', TokenLine}}.
\[  : {token, {'[', TokenLine}}.
\]  : {token, {']', TokenLine}}.
=   : {token, {'=', TokenLine}}.
:   : {token, {':', TokenLine}}.
,   : {token, {',', TokenLine}}.

Erlang code.

identifier("include", TokenLine)  -> {directive, TokenLine, 'include'};
identifier(TokenChars, TokenLine) -> {atom, TokenLine, list_to_atom(TokenChars)}.

bool("true")  -> true;
bool("false") -> false;
bool("on")    -> true;
bool("off")   -> false.

unquote(Str) -> string:strip(Str, both, $").

