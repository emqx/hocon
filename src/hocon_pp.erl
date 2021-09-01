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

-export([do/1]).

%% random magic bytes to work as newline instead of "\n"
-define(NL, <<"magic-chicken", 255, 156, 173, 82, 187, 168, 136>>).
-define(INDENT, "  ").

do(Value) ->
    [[Line, "\n"] || Line <- split(fmt(gen(Value)))].

gen([]) -> <<"\"\"">>;
gen(I) when is_integer(I) -> integer_to_binary(I);
gen(F) when is_float(F) -> float_to_binary(F, [{decimals, 6}, compact]);
gen(A) when is_atom(A) -> atom_to_binary(A, utf8);
gen(Bin) when is_binary(Bin) ->
    gen(unicode:characters_to_list(Bin, utf8));
gen(S) when is_list(S) ->
    case io_lib:printable_unicode_list(S) of
        true  -> bin(io_lib:format("~100000p", [S]));
        false -> gen_list(S)
    end;
gen(M) when is_map(M) ->
    gen_map(M).

gen_list(L) ->
    [ ["[", ?NL]
    , [{indent, [gen(I), ?NL]} || I <- L]
    , ["]", ?NL]
    ].

gen_map(M) ->
    [ ["{", ?NL]
    , [{indent, [K, " = ", gen(V), ?NL]} || {K, V} <- maps:to_list(M)]
    , ["}", ?NL]
    ].

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
