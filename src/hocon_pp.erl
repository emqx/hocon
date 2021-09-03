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

-module(hocon_pp).

-export([do/2]).

-include("hocon_private.hrl").

-define(INDENT, "  ").

%% @doc Pretty print HOCON value.
%% Options are:
%% `embedded': boolean, to indicate if the given value is an embedded part
%% of a wrapping ojbect, when `true', `{' and `}' are wrapped around the fields.
%%
%% `newline': string, by default `"\n"' is used, for generating web-content
%% it should be `"<br>"' instead.
-spec do(term(), map()) -> iodata().
do(Value, Opts) when is_map(Value) ->
    %% Root level map should not have outter '{' '}' pair
    case maps:get(embedded, Opts, false) of
        true ->
            pp(fmt(gen(Value, Opts)), Opts);
        false ->
            pp(fmt(gen_map_fields(Value, Opts, ?NL)), Opts)
    end;
do(Value, Opts) ->
    pp(fmt(gen(Value, Opts)), Opts).

pp(IoData, Opts) ->
    NewLine = maps:get(newline, Opts, "\n"),
    infix(split(bin(IoData)), NewLine).

gen([], _Opts) -> <<"[]">>;
gen(<<>>, _Opts) -> <<"\"\"">>;
gen(I, _Opts) when is_integer(I) -> integer_to_binary(I);
gen(F, _Opts) when is_float(F) -> float_to_binary(F, [{decimals, 6}, compact]);
gen(A, _Opts) when is_atom(A) -> atom_to_binary(A, utf8);
gen(Bin, Opts) when is_binary(Bin) ->
    gen(unicode:characters_to_list(Bin, utf8), Opts);
gen(S, Opts) when is_list(S) ->
    case io_lib:printable_unicode_list(S) of
        true  ->
            %% ~p to ensure always quote string value
            bin(io_lib:format("~100000p", [S]));
        false ->
            gen_list(S, Opts)
    end;
gen(M, Opts) when is_map(M) ->
    gen_map(M, Opts).


gen_list(L, Opts) ->
    case is_oneliner(L) of
        true ->
            %% one line
            ["[", infix([gen(I, Opts) || I <- L], ", "), "]"];
        false ->
            do_gen_list(L, Opts)
    end.

do_gen_list(L, Opts) ->
    [ ["[", ?NL]
    , [{indent, [gen(I, Opts), ",", ?NL]} || I <- L]
    , ["]", ?NL]
    ].

is_oneliner(L) when is_list(L) ->
    lists:all(fun(X) -> is_number(X) orelse is_binary(X) orelse is_atom(X) end, L);
is_oneliner(M) when is_map(M) ->
    maps:size(M) < 3 andalso is_oneliner(maps:values(M)).

gen_map(M, Opts) ->
    case is_oneliner(M) of
        true -> ["{", infix(gen_map_fields(M, Opts, ""), ", "), "}"];
        false -> [ ["{", ?NL], {indent, gen_map_fields(M, Opts, ?NL)} , ["}", ?NL] ]
    end.

gen_map_fields(M, Opts, NL) ->
    [gen_map_field(K, V, Opts, NL) || {K, V} <- maps:to_list(M)].

gen_map_field(K, V, Opts, NL) when is_map(V) ->
    [maybe_quote(K), " ", gen(V, Opts), NL];
gen_map_field(K, V, Opts, NL) ->
    [maybe_quote(K), " = ", gen(V, Opts), NL].

%% maybe quote key
maybe_quote(K) ->
    case re:run(K, "[^A-Za-z_]") of
        nomatch -> K;
        _ -> io_lib:format("~100000p", [unicode:characters_to_list(K, utf8)])
    end.

bin(IoData) -> iolist_to_binary(IoData).

fmt(I) when is_integer(I) -> I;
fmt(B) when is_binary(B) -> B;
fmt(L) when is_list(L) ->
    bin(lists:map(fun fmt/1, L));
fmt({indent, Block}) ->
    FormatedBlock = fmt(Block),
    bin([[?INDENT, Line, ?NL] || Line <- split(FormatedBlock)]).

split(Bin) ->
    [Line || Line <- binary:split(Bin, ?NL, [global]), Line =/= <<>>].

infix([], _) -> [];
infix([One], _) -> [One];
infix([H | T], Infix) -> [[H, Infix] | infix(T, Infix)].
