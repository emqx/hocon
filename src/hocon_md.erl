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

-module(hocon_md).

-export([h/2, link/2, local_link/2, th/1, td/1, ul/1, code/1]).
-export([join/1, indent/2]).

h(1, Text) -> format("# ~s~n", [Text]);
h(2, Text) -> format("## ~s~n", [Text]);
h(3, Text) -> format("### ~s~n", [Text]);
h(4, Text) -> format("#### ~s~n", [Text]);
h(5, Text) -> format("##### ~s~n", [Text]);
h(6, Text) -> format("###### ~s~n", [Text]).

link(Text, Link) -> format("[~s](~s)", [Text, Link]).

local_link(Text, Anchor) ->
    format("[~s](#~s)", [Text, anchor(Anchor)]).

th(Elements) ->
    Alignment = lists:join("|", ["----" || _ <- lists:seq(0, length(Elements) - 1)]),
    format("~s~n~s~n", [lists:join("|", Elements), Alignment]).

td(Elements) ->
    format("~s~n", [lists:join("|", [escape_bar(E) || E <- Elements])]).

ul(Elements) ->
    lists:flatten([format("- ~s~n", [E]) || E <- Elements] ++ "\n").

format(Template, Values) ->
    lists:flatten(io_lib:format(Template, Values)).

escape_bar(Str) ->
    lists:flatten(string:replace(Str, "|", "&#124;", all)).

code(Text) -> ["<code>", Text, "</code>"].

join(Mds) ->
    lists:join("\n", [Mds]).

indent(N, Lines) when is_list(Lines) ->
    indent(N, unicode:characters_to_binary(infix(Lines, "\n"), utf8));
indent(N, Lines0) ->
    Pad = lists:duplicate(N, $\s),
    Lines = binary:split(Lines0, <<"\n">>, [global]),
    infix([pad(Pad, Line) || Line <- Lines], "\n").

pad(_Pad, <<>>) -> <<>>;
pad(Pad, Line) -> [Pad, Line].

infix([], _) -> [];
infix([X], _) -> [X];
infix([H | T], In) -> [H, In | infix(T, In)].

%% ref: https://gist.github.com/asabaylus/3071099
%% GitHub flavored markdown likes ':' being removed
%% VuePress likes ':' being replaced by '-'
anchor(Anchor0) ->
    Anchor = string:lowercase(bin(Anchor0)),
    %% no dot
    Replaces = [
        {<<"\\.">>, <<"">>},
        %% no single quotes
        {<<"'">>, <<"">>},
        %% vuepress
        {<<":">>, <<"-">>},
        %% space replaced by hyphen
        {<<"\\s">>, <<"-">>}
    ],
    lists:foldl(
        fun({Pattern, Replace}, Acc) ->
            re:replace(
                Acc,
                Pattern,
                Replace,
                [{return, list}, global]
            )
        end,
        Anchor,
        Replaces
    ).

bin(S) when is_list(S) -> unicode:characters_to_binary(S, utf8);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(B) when is_binary(B) -> B.
