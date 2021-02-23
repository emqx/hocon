-module(elvis_more_rules).

-export([enhanced_operator_spaces/3]).

enhanced_operator_spaces(_Config, Target, _RuleConfig) ->
    {Src, _} = src(Target),
    Lines = lists:map(fun binary_to_list/1, binary:split(Src, <<"\n">>, [global])),
    check_operator_spaces(Lines).

check_operator_spaces(Lines) ->
    check_operator_spaces(Lines, [], false, 1).
check_operator_spaces([], Acc, _Q, _L) ->
    lists:flatten(Acc);
check_operator_spaces([Line | More], Acc, Q, LineNum) ->
    case do_check_operator_spaces(Line, [], Q, LineNum) of
        {[], NewQ} ->
            check_operator_spaces(More, Acc, NewQ, LineNum + 1);
        {Warnings, NewQ} ->
            check_operator_spaces(More, [Warnings | Acc], NewQ, LineNum + 1)
    end.
do_check_operator_spaces([], Warnings, Q, _L) ->
    {Warnings, Q};
do_check_operator_spaces([$% | _], Warnings, false, _L) ->
    {Warnings, false};

do_check_operator_spaces([$" | More], Warnings, Q, L) ->
    do_check_operator_spaces(More, Warnings, not Q, L);
do_check_operator_spaces([$\\, $" | More], Warnings, Q, L) ->
    do_check_operator_spaces(More, Warnings, Q, L);
do_check_operator_spaces([_Other | More], Warnings, true, L) ->
    do_check_operator_spaces(More, Warnings, true, L);

do_check_operator_spaces([$\s, $) | More], Warnings, Q, L) ->
    W = create_warning(delete, left, ")", L),
    do_check_operator_spaces([$) | More], [W | Warnings], Q, L);
do_check_operator_spaces([$$, $( | More], Warnings, Q, L) ->
    do_check_operator_spaces(More, Warnings, Q, L);
do_check_operator_spaces([$(, $\s | More], Warnings, Q, L) ->
    W = create_warning(delete, right, "(", L),
    do_check_operator_spaces([$\s | More], [W | Warnings], Q, L);

do_check_operator_spaces([$$, $| | More], Warnings, Q, L) ->
    do_check_operator_spaces(More, Warnings, Q, L);
do_check_operator_spaces([$|, $|, Right | More], Warnings, Q, L) when Right =/= $\s ->
    W = create_warning(missing, right, "||", L),
    do_check_operator_spaces([Right | More], [W | Warnings], Q, L);
do_check_operator_spaces([$|, $|, Space | More], Warnings, Q, L) ->
    do_check_operator_spaces([Space | More], Warnings, Q, L);
do_check_operator_spaces([Left, $|, $| | More], Warnings, Q, L) when Left =/= $\s ->
    W = create_warning(missing, left, "||", L),
    do_check_operator_spaces([$|, $| | More], [W | Warnings], Q, L);
do_check_operator_spaces([_Space, $|, $| | More], Warnings, Q, L) ->
    do_check_operator_spaces([$|, $| | More], Warnings, Q, L);

do_check_operator_spaces([$|, Right | More], Warnings, Q, L) when Right =/= $\s ->
    W = create_warning(missing, right, "|", L),
    do_check_operator_spaces([Right | More], [W | Warnings], Q, L);
do_check_operator_spaces([Left, $| | More], Warnings, Q, L) when Left =/= $\s ->
    W = create_warning(missing, left, "|", L),
    do_check_operator_spaces([$| | More], [W | Warnings], Q, L);

do_check_operator_spaces([_Other | More], Warnings, Q, L) ->
    do_check_operator_spaces(More, Warnings, Q, L).

create_warning(delete, Position, Operator, Line) ->
    #{message => "Delete spaces ~s ~p on line ~p",
      info => [Position, Operator, Line],
      line_num => Line};
create_warning(missing, Position, Operator, Line) ->
    #{message => "Missing spaces ~s ~p on line ~p",
      info => [Position, Operator, Line],
      line_num => Line}.

-type file() :: #{path => string(), content => binary(), _ => _}.
-spec src(file()) ->
    {binary(), file()} | {error, enoent}.
src(File = #{content := Content, encoding := _}) ->
    {Content, File};
src(File = #{content := Content}) ->
    {Content, File#{encoding => find_encoding(Content)}};
src(File = #{path := Path}) ->
    case file:read_file(Path) of
        {ok, Content} ->
            Encoding = find_encoding(Content),
            src(File#{content => Content,
                      encoding => Encoding});
        Error -> Error
    end;
src(File) ->
    throw({invalid_file, File}).

find_encoding(Content) ->
    case epp:read_encoding_from_binary(Content) of
        none -> utf8;
        Enc  -> Enc
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
this_file_test() ->
    avoid_warnings(),
    Warnings = enhanced_operator_spaces([], #{path => "elvis_more_rules.erl"}, []),
    ?assertEqual(17, length(Warnings)).

whitespace_around_bar([ok|T]) -> % 4
    [[ok| T],
     [ok |T],
     [ok | T]];
whitespace_around_bar([$| | T]) -> T.

whitespace_around_comprehension(X) -> % 4
    [A||A <- X],
    [A ||A <- X],
    [A|| A <- X],
    [A || A <- X].

no_spaces_paren( 1) -> ng; %4
no_spaces_paren( 2 ) -> ng;
no_spaces_paren(3 ) -> ng;
no_spaces_paren(4) -> ok;
no_spaces_paren([$( | []]) -> ok;
no_spaces_paren($)) -> ok.

quote_intervention(1) -> % 3
    "$";
quote_intervention(2) ->
    [ng| []];
quote_intervention(3) ->
    "%";
quote_intervention(4) ->
    [ng| []];
quote_intervention(5) ->
    "\"";
quote_intervention(_) ->
    [ng| []].

multiline_quote_intervention(ok) ->
    "it is allowed to write
     ( X ) , [H|T] or [A||A<-X]
     in quoted string";
multiline_quote_intervention(_) -> [ng| []]. % 1

% it is allowed to write ( X ) , [H|T] or [A||A<-X] when commented out

it_resumes_when_comment_ends() -> [ng| []]. % 1

avoid_warnings() ->
    %avoid 'unused' warnings
    whitespace_around_bar([ok | []]),
    whitespace_around_comprehension([]),
    no_spaces_paren(1),
    quote_intervention(ok),
    multiline_quote_intervention(ok),
    it_resumes_when_comment_ends().

-endif.
