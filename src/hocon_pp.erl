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

%% either '\n' or '\r\n' depending on the `newline` option in the `Opts` map.
-define(NL, newline).
%% '\n' for triple quote string, not used anywhere else.
-define(LF, lf).
%% '\r\n' for triple quote string, not used anywhere else.
-define(CRLF, crlf).
-define(TRIPLE_QUOTE, <<"\"\"\"">>).
-define(INDENT_STEP, 2).

-type line() :: binary().

%% @doc Pretty print HOCON value.
%% Options are:
%% `embedded': boolean, to indicate if the given value is an embedded part
%% of a wrapping object, when `true', `{' and `}' are wrapped around the fields.
%%
%% `newline': string, by default `"\n"' is used, for generating web-content
%% it should be `"<br/>"' instead.
%%
%% `no_obj_nl': boolean, default to `false'. When set to `true' no new line
%% is added after objects.
%%
%% Return a list of binary strings, each list element is a line.
-spec do(term(), map()) -> [line()].
do(Value, Opts0) when is_map(Value) ->
    Opts = Opts0#{indent => 0},
    %% Root level map should not have outer '{' '}' pair
    case maps:get(embedded, Opts, false) of
        true ->
            fmt(gen(Value, Opts), Opts);
        false ->
            fmt(gen_map_fields(Value, Opts, multiline), Opts)
    end;
do(Value, Opts0) ->
    Opts = Opts0#{indent => 0},
    fmt(gen(Value, Opts), Opts).

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
        [Path, " = ", pp_flat_value(Value), real_nl()]
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
            gen_str(S, latin1, Opts);
        false ->
            case io_lib:printable_unicode_list(S) of
                true -> gen_str(S, unicode, Opts);
                false -> gen_list(S, Opts)
            end
    end;
gen(M, Opts) when is_map(M) ->
    NL =
        case maps:get(no_obj_nl, Opts, false) of
            true -> "";
            false -> ?NL
        end,
    [gen_map(M, Opts), NL];
gen(F, #{lazy_evaluator := Evaluator} = Opts) when is_function(F, 0) ->
    %% a lazy value, e.g. secret data
    Value = Evaluator(F),
    gen(Value, Opts);
gen(Value, Opts) ->
    throw(#{
        reason => unsupported_value,
        value => Value,
        options => Opts
    }).

gen_str(S, Codec, Opts) ->
    case (not is_oneliner_opt(Opts)) andalso is_triple_quote_str(S) of
        true ->
            gen_triple_quote_str(S, Opts);
        false ->
            gen_single_quote_str(S, Codec)
    end.

%% If a string requires escaping, it is a triple quote string
%% with one exception: if the string itself contains triple-quote
is_triple_quote_str(Chars) ->
    case has_triple_quotes(Chars) of
        true ->
            false;
        false ->
            lists:any(fun(C) -> esc(C) =/= C end, Chars)
    end.

%% Return 'true' if there are three consecutive quotes in a string.
has_triple_quotes(Chars) ->
    nomatch =/= string:find(Chars, "\"\"\"").

%% If a string has '\n' in it, it's a multiline.
%% If it has leading or trailing quotes,
%% it's a multiline -- so that there is no need to escape the quotes.
is_multiline([]) ->
    false;
is_multiline(Chars) ->
    lists:member($\n, Chars) orelse is_leading_quote(Chars) orelse is_trailling_quote(Chars).

is_leading_quote([$" | _]) -> true;
is_leading_quote(_) -> false.

is_trailling_quote(Chars) ->
    is_leading_quote(lists:reverse(Chars)).

gen_single_quote_str(S, latin1) ->
    maybe_quote_latin1_str(S);
gen_single_quote_str(S, unicode) ->
    <<"\"", (format_escape_sequences(S))/binary, "\"">>.

gen_triple_quote_str(Str, Opts) ->
    [
        ?TRIPLE_QUOTE,
        maybe_indent(Str, Opts),
        ?TRIPLE_QUOTE
    ].

maybe_indent(Chars, Opts) ->
    case is_multiline(Chars) of
        true ->
            ["~", ?NL, indent_multiline_str(Chars, indent_inc(Opts)), "~"];
        false ->
            Chars
    end.

indent_multiline_str(Chars, Opts) ->
    Lines = split_lines(Chars),
    indent_str_value_lines(Lines, Opts).

%% Split the lines with '\n' and and remove the trailing '\n' from each line.
%% Keep '\r' as a a part of the line because `\n` will be added back.
split_lines(Chars) ->
    split_lines(Chars, [], []).

split_lines([], LastLineR, Lines) ->
    LastLine = lists:reverse(LastLineR),
    lists:reverse([LastLine | Lines]);
split_lines([$\n | Chars], Line, Lines) ->
    split_lines(Chars, [], [lists:reverse(Line) | Lines]);
split_lines([Char | Chars], Line, Lines) ->
    split_lines(Chars, [Char | Line], Lines).

real_nl() ->
    io_lib:nl().

%% Mark each line for indentation with 'indent'
%% except for empty lines in the middle of the string.
%% Insert '\n', but not real_nl() because '\r' is treated as value when splitted.
indent_str_value_lines([[]], Opts) ->
    %% last line being empty, indent less for the closing triple-quote
    [indent(indent_dec(Opts))];
indent_str_value_lines([[$\r]], Opts) ->
    %% last line being empty, indent less for the closing triple-quote
    [indent(indent_dec(Opts))];
indent_str_value_lines([[] | Lines], Opts) ->
    %% do not indent empty line
    [?LF | indent_str_value_lines(Lines, Opts)];
indent_str_value_lines([[$\r] | Lines], Opts) ->
    %% do not indent empty line
    [?CRLF | indent_str_value_lines(Lines, Opts)];
indent_str_value_lines([LastLine], Opts) ->
    %% last line is not empty
    [indent(Opts), LastLine];
indent_str_value_lines([Line | Lines], Opts) ->
    [indent(Opts), Line, ?LF | indent_str_value_lines(Lines, Opts)].

gen_list(L, Opts) ->
    case is_oneliner(L, Opts) of
        true ->
            %% one line
            ["[", infix([gen(I, Opts) || I <- L], ", "), "]"];
        false ->
            gen_multiline_list(L, Opts)
    end.

gen_multiline_list([_ | _] = L, Opts) ->
    [
        ["["],
        gen_multiline_list_loop(L, indent_inc(Opts#{no_obj_nl => true})),
        [nl_indent(Opts), "]"]
    ].

gen_multiline_list_loop([I], Opts) ->
    [nl_indent(Opts), gen(I, Opts)];
gen_multiline_list_loop([H | T], Opts) ->
    [nl_indent(Opts), gen(H, Opts), "," | gen_multiline_list_loop(T, Opts)].

is_oneliner_opt(Opts) ->
    NL = opts_nl(Opts),
    NL =:= "" orelse NL =:= <<>>.

is_oneliner(Value, Opts) ->
    is_oneliner_opt(Opts) orelse is_oneliner(Value).

is_oneliner(L) when is_list(L) ->
    lists:all(
        fun(X) ->
            is_number(X) orelse
                is_atom(X) orelse
                is_simple_short_string(X)
        end,
        L
    );
is_oneliner(M) when is_map(M) ->
    maps:size(M) < 3 andalso is_oneliner(maps:values(M)).

is_simple_short_string(X) ->
    try
        Str = bin(X),
        size(Str) =< 40 andalso is_simple_string(Str)
    catch
        _:_ ->
            false
    end.

%% Contain $"{}[]:=,+#`^?!@*& \ should be quoted
%% And .- are allowed per spec, but considered not-simple per our standard
%% Also strings start with a digit is not-simple
is_simple_string(<<D, _/binary>>) when D >= $0 andalso D =< $9 ->
    false;
is_simple_string([D | _]) when D >= $0 andalso D =< $9 ->
    false;
is_simple_string(Str) ->
    case re:run(Str, "^[^$\"{}\\[\\]:=,+#`\\^?!@*&\\ \\\\\n\\.\\-]*$") of
        nomatch -> false;
        _ -> true
    end.

gen_map(M, Opts) ->
    case is_oneliner(M, Opts) of
        true ->
            ["{", infix(gen_map_fields(M, Opts, oneline), ", "), "}"];
        false ->
            [
                "{",
                ?NL,
                gen_map_fields(M, indent_inc(Opts), multiline),
                nl_indent(Opts),
                "}"
            ]
    end.

gen_map_fields(M, Opts, oneline) ->
    [gen_map_field(K, V, Opts) || {K, V} <- map_to_list(M)];
gen_map_fields(M, Opts, multiline) ->
    Fields = map_to_list(M),
    F = fun({K, V}) -> [indent(Opts), gen_map_field(K, V, Opts), ?NL] end,
    lists:map(F, Fields).

%% sort the map fields by key
map_to_list(M) ->
    lists:keysort(1, [{bin(K), V} || {K, V} <- maps:to_list(M)]).

gen_map_field(K, V, Opts) when is_map(V) ->
    [maybe_quote_key(K), " ", gen(V, Opts)];
gen_map_field(K, V, Opts) ->
    [maybe_quote_key(K), " = ", gen(V, Opts)].

maybe_quote_key(K) when is_atom(K) -> atom_to_list(K);
maybe_quote_key(K0) ->
    case is_quote_key(unicode:characters_to_list(K0, utf8)) of
        true ->
            K1 = unicode:characters_to_list(K0, utf8),
            <<"\"", (format_escape_sequences(K1))/binary, "\"">>;
        false ->
            K0
    end.

is_quote_key(K) ->
    case io_lib:printable_latin1_list(K) of
        true ->
            %% key begin with a-zA-Z should not be quote
            case re:run(K, "^[a-zA-Z]+[A-Za-z0-9-_]*$") of
                nomatch -> true;
                _ -> false
            end;
        false ->
            true
    end.

%% Return 'true' if a string is to be quoted when formatted as HOCON.
%% A sequence of characters outside of a quoted string is a string value if:
%% it does not contain "forbidden characters":
%% '$', '"', '{', '}', '[', ']', ':', '=', ',', '+', '#', '`', '^', '?', '!', '@', '*',
%% '&', '' (backslash), or whitespace.
%% '$"{}[]:=,+#`^?!@*& \\'
%% NOTE '.' and '-' are not forbidden characters, but we decide to quote such strings anyway.
%% This is because lib implemented in other languages (e.g. GoLang) cannot handle unquoted
%% strings like `tlsv1.3`
is_to_quote_str(S) ->
    case hocon_scanner:string(S) of
        {ok, [{Tag, 1, S}], 1} when Tag =:= string orelse Tag =:= unqstr ->
            not is_simple_string(S);
        _ ->
            true
    end.

maybe_quote_latin1_str(S) ->
    case is_to_quote_str(S) of
        true -> bin(io_lib:format("~0p", [S]));
        false -> S
    end.

bin(A) when is_atom(A) ->
    atom_to_binary(A);
bin(IoData) ->
    try unicode:characters_to_binary(IoData, utf8) of
        Bin when is_binary(Bin) -> Bin;
        _ -> iolist_to_binary(IoData)
    catch
        _:_ -> iolist_to_binary(IoData)
    end.

fmt(Tokens, Opts) ->
    Flatten = flatten(Tokens),
    render_nl(Flatten, [], [], opts_nl(Opts)).

opts_nl(Opts) ->
    maps:get(newline, Opts, real_nl()).

render_nl([], LastLine, Lines, _NL) ->
    lists:reverse(add_line_r(lists:reverse(LastLine), Lines));
render_nl([?CRLF | Rest], Line0, Lines, NL) ->
    Line = lists:reverse([$\n, $\r | Line0]),
    render_nl(Rest, [], add_line_r(Line, Lines), NL);
render_nl([?LF | Rest], Line0, Lines, NL) ->
    Line = lists:reverse([$\n | Line0]),
    render_nl(Rest, [], add_line_r(Line, Lines), NL);
render_nl([?NL | Rest], Line0, Lines, NL) ->
    Line = lists:reverse([NL | Line0]),
    render_nl(Rest, [], add_line_r(Line, Lines), NL);
render_nl([Token | Rest], Line, Lines, NL) ->
    render_nl(Rest, [Token | Line], Lines, NL).

add_line_r(Line, Lines) when is_list(Line) ->
    add_line_r(bin(Line), Lines);
add_line_r(<<>>, Lines) ->
    Lines;
add_line_r(Line, Lines) ->
    [Line | Lines].

flatten([]) ->
    [];
flatten([I | T]) when is_integer(I) ->
    [I | flatten(T)];
flatten([B | T]) when is_binary(B) ->
    [B | flatten(T)];
flatten([L | T]) when is_list(L) ->
    flatten(L ++ T);
flatten([?CRLF | T]) ->
    [?CRLF | flatten(T)];
flatten([?LF | T]) ->
    [?LF | flatten(T)];
flatten([?NL | T]) ->
    [?NL | dedup_nl(flatten(T))];
flatten(B) when is_binary(B) ->
    [B].

indent_dec(#{indent := Level} = Opts) ->
    Opts#{indent => Level - ?INDENT_STEP}.

indent_inc(#{indent := Level} = Opts) ->
    Opts#{indent => Level + ?INDENT_STEP}.

%% indent if there is already on a new line
indent(#{indent := Level}) ->
    indent(Level);
indent(Level) ->
    lists:duplicate(Level, $\s).

%% move to new line and indent
nl_indent(#{indent := Level}) ->
    nl_indent(Level);
nl_indent(Level) ->
    [?NL, indent(Level)].

%% The inserted ?NL tokens might be redundant due to the lack of "look ahead" when generating.
dedup_nl([?NL | T]) ->
    dedup_nl(T);
dedup_nl(Tokens) ->
    Tokens.

infix(List, Sep) ->
    lists:join(Sep, List).

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

-include_lib("eunit/include/eunit.hrl").
-ifdef(TEST).
simple_string_test_() ->
    [
        ?_assert(is_simple_string("")),
        ?_assert(is_simple_string("simpleText")),
        ?_assert(is_simple_string("simpleText123")),
        ?_assertNot(is_simple_string("896KB")),
        ?_assertNot(is_simple_string(<<"896KB">>)),
        ?_assertNot(is_simple_string("123")),
        ?_assertNot(is_simple_string("tlsv1.3")),
        ?_assertNot(is_simple_string("price${amount}")),
        ?_assertNot(is_simple_string("text with space")),
        ?_assertNot(is_simple_string("line1\nline2")),
        ?_assertNot(is_simple_string("non-simple")),
        ?_assertNot(is_simple_string("non.simple")),
        ?_assertNot(is_simple_string("user@example.com")),
        ?_assertNot(is_simple_string("escaped\\character")),
        ?_assertNot(is_simple_string("Hello, World!"))
    ].

gen_str_test_() ->
    [
        {"empty-string", ?_assertEqual(<<"\"\"">>, gen(<<"">>, #{}))},
        {"empty-array", ?_assertEqual(<<"[]">>, gen([], #{}))}
    ].

-endif.
