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

-module(hocon_pp).

-export([do/2, flat_dump/1]).

-include("hocon_private.hrl").

-define(INDENT, "  ").

%% @doc Pretty print HOCON value.
%% Options are:
%% `embedded': boolean, to indicate if the given value is an embedded part
%% of a wrapping object, when `true', `{' and `}' are wrapped around the fields.
%%
%% `newline': string, by default `"\n"' is used, for generating web-content
%% it should be `"<br>"' instead.
%%
%% `no_obj_nl': boolean, default to `false'. When set to `true' no new line
%% is added after objects.
-spec do(term(), map()) -> iodata().
do(Value, Opts) when is_map(Value) ->
    %% Root level map should not have outer '{' '}' pair
    case maps:get(embedded, Opts, false) of
        true ->
            pp(fmt(gen(Value, Opts)), Opts);
        false ->
            pp(fmt(gen_map_fields(Value, Opts, ?NL)), Opts)
    end;
do(Value, Opts) ->
    pp(fmt(gen(Value, Opts)), Opts).

%% @doc Print nested objects as flat 'path.to.key = value' pairs.
%% Paths for array elements are as 1 based index numbers.
%% When the input config is a richmap, original location is printed.
-spec flat_dump(hocon:config()) -> iodata().
flat_dump(Value) ->
    Flatten = hocon_maps:flatten(Value, #{rich_value => true}),
    pp_flat(Flatten).

pp_flat([]) ->
    [];
pp_flat([{Path, Value} | Rest]) ->
    [
        [Path, " = ", pp_flat_value(Value), "\n"]
        | pp_flat(Rest)
    ].

pp_flat_value(#{?HOCON_V := Value} = V) ->
    [pp_flat_value(Value), pp_source(maps:get(?METADATA, V, undefined))];
pp_flat_value(V) ->
    gen(V, #{}).

pp_source(#{from_env := Env}) ->
    [" # ", Env];
pp_source(#{filename := F, line := Line}) ->
    [" # ", F, ":", integer_to_list(Line)];
pp_source(#{line := Line}) ->
    [" # line=", integer_to_list(Line)];
pp_source(undefined) ->
    "".

pp(IoData, Opts) ->
    NewLine = maps:get(newline, Opts, "\n"),
    [[Line, NewLine] || Line <- split(bin(IoData))].

gen([], _Opts) ->
    <<"[]">>;
gen(<<>>, _Opts) ->
    <<"\"\"">>;
gen('', _Opts) ->
    <<"\"\"">>;
gen(null, _Opts) ->
    <<"null">>;
gen(I, _Opts) when is_integer(I) -> integer_to_binary(I);
gen(F, _Opts) when is_float(F) -> float_to_binary(F, [{decimals, 6}, compact]);
gen(B, _Opts) when is_boolean(B) -> atom_to_binary(B);
gen(A, Opts) when is_atom(A) -> gen(atom_to_list(A), Opts);
gen(Bin, Opts) when is_binary(Bin) ->
    Str = unicode:characters_to_list(Bin, utf8),
    case is_list(Str) of
        true -> gen(Str, Opts);
        false -> throw({invalid_utf8, Bin})
    end;
gen(S, Opts) when is_list(S) ->
    case io_lib:printable_latin1_list(S) of
        true ->
            maybe_quote_latin1_str(S);
        false ->
            case io_lib:printable_unicode_list(S) of
                true -> <<"\"", (format_escape_sequences(S))/binary, "\"">>;
                false -> gen_list(S, Opts)
            end
    end;
gen(M, Opts) when is_map(M) ->
    NL =
        case maps:get(no_obj_nl, Opts, false) of
            true -> "";
            false -> ?NL
        end,
    [gen_map(M, Opts), NL].

gen_list(L, Opts) ->
    case is_oneliner(L) of
        true ->
            %% one line
            ["[", infix([gen(I, Opts) || I <- L], ", "), "]"];
        false ->
            do_gen_list(L, Opts)
    end.

do_gen_list([_ | _] = L, Opts) ->
    [
        ["[", ?NL],
        do_gen_list_loop(L, Opts#{no_obj_nl => true}),
        ["]", ?NL]
    ].

do_gen_list_loop([I], Opts) ->
    [{indent, gen(I, Opts)}];
do_gen_list_loop([H | T], Opts) ->
    [{indent, [gen(H, Opts), ","]} | do_gen_list_loop(T, Opts)].

is_oneliner(L) when is_list(L) ->
    lists:all(fun(X) -> is_number(X) orelse is_binary(X) orelse is_atom(X) end, L);
is_oneliner(M) when is_map(M) ->
    maps:size(M) < 3 andalso is_oneliner(maps:values(M)).

gen_map(M, Opts) ->
    case is_oneliner(M) of
        true -> ["{", infix(gen_map_fields(M, Opts, ""), ", "), "}"];
        false -> [["{", ?NL], {indent, gen_map_fields(M, Opts, ?NL)}, "}"]
    end.

gen_map_fields(M, Opts, NL) ->
    [gen_map_field(K, V, Opts, NL) || {K, V} <- maps:to_list(M)].

gen_map_field(K, V, Opts, NL) when is_map(V) ->
    [maybe_quote_key(K), " ", gen(V, Opts), NL];
gen_map_field(K, V, Opts, NL) ->
    [maybe_quote_key(K), " = ", gen(V, Opts), NL].

maybe_quote_key(K) when is_atom(K) -> atom_to_list(K);
maybe_quote_key(K0) ->
    case is_quote_key(K0) of
        true ->
            K1 = unicode:characters_to_list(K0, utf8),
            <<"\"", (format_escape_sequences(K1))/binary, "\"">>;
        false ->
            K0
    end.

is_quote_key(K) ->
    %% key contain _ should not be quoted
    need_quote(K, "[^A-Za-z0-9_]").

need_quote(Str, Patten) ->
    case re:run(Str, Patten) of
        nomatch -> is_digit(Str);
        _ -> true
    end.

is_quote_str(S) ->
    %% string contain _ should be quoted
    need_quote(S, "[^A-Za-z0-9]").

maybe_quote_latin1_str(S) ->
    case is_quote_str(S) of
        true -> bin(io_lib:format("~0p", [S]));
        false -> S
    end.

is_digit(S) ->
    case string:to_integer(S) of
        {_, []} -> true;
        {_, <<>>} -> true;
        _ -> false
    end.

bin(IoData) ->
    try unicode:characters_to_binary(IoData, utf8) of
        Bin when is_binary(Bin) -> Bin;
        _ -> iolist_to_binary(IoData)
    catch
        _:_ -> iolist_to_binary(IoData)
    end.

fmt(I) when is_integer(I) -> I;
fmt(B) when is_binary(B) -> B;
fmt(L) when is_list(L) ->
    bin(lists:map(fun fmt/1, L));
fmt({indent, Block}) ->
    FormattedBlock = fmt(Block),
    bin([[?INDENT, Line, ?NL] || Line <- split(FormattedBlock)]).

split(Bin) ->
    [Line || Line <- binary:split(Bin, ?NL, [global]), Line =/= <<>>].

infix([], _) -> [];
infix([One], _) -> [One];
infix([H | T], Infix) -> [[H, Infix] | infix(T, Infix)].

format_escape_sequences(Str) ->
    bin(lists:map(fun esc/1, Str)).

% LF
esc($\n) -> "\\n";
% CR
esc($\r) -> "\\r";
% TAB
esc($\t) -> "\\t";
% VT
esc($\v) -> "\\v";
% FF
esc($\f) -> "\\f";
% BS
esc($\b) -> "\\b";
% ESC
esc($\e) -> "\\e";
% DEL
esc($\d) -> "\\d";
% "
esc($\") -> "\\\"";
% \
esc($\\) -> "\\\\";
esc(Char) -> Char.
