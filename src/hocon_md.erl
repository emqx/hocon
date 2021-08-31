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

-module(hocon_md).

-export([h/2, link/2, local_link/2, th/1, td/1, ul/1, code/1]).
-export([join/1]).

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

code(Text) -> format("<code>~s</code>", [Text]).

join(Mds) ->
    lists:join("\n", [Mds]).

%% ref: https://gist.github.com/asabaylus/3071099
anchor(Anchor0) ->
    Anchor = string:lowercase(bin(Anchor0)),
    Replaces = [{<<"\\.">>, <<"">>}, %% no dot
                {<<"'">>, <<"">>}, %% no single quotes
                {<<":">>, <<"">>}, %% no colon
                {<<"\\s">>, <<"-">>} %% space replaced by hyphen
               ],
    lists:foldl(fun({Pattern, Replace}, Acc) ->
                        re:replace(Acc, Pattern, Replace,
                                   [{return, list}, global])
                end, Anchor, Replaces).

bin(S) when is_list(S) -> unicode:characters_to_binary(S, utf8);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8).
