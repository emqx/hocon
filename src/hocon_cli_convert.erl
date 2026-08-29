%%--------------------------------------------------------------------
%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon_cli_convert).

-export([main/1]).

-define(STDERR(Str, Args), io:format(standard_error, Str ++ "~n", Args)).

usage(OutputStream) ->
    getopt:usage(
        cli_options(),
        "hocon-convert",
        "[<HOCON-FILE> ...]",
        "Convert HOCON configuration to JSON or YAML.\n"
        "Positional arguments are HOCON files; when omitted, input is read from standard input.",
        [],
        OutputStream
    ).

cli_options() ->
    %% Option Name, Short Code, Long Code, Argument Spec, Help Message
    [
        {help, $h, "help", undefined, "Print usage and exit"},
        {include_dirs, $I, "include_dir", string,
            "Specifies the search directory for included files"},
        {output, $o, "output", {string, "-"},
            "Specifies where to write converted output, `-` is stdout"},
        {format, $F, "format", {string, "json"},
            "Specifies output format, `json` and `yaml` are supported"}
    ].

main(Args) ->
    case getopt:parse(cli_options(), Args) of
        {ok, {Opts, PosArgs}} ->
            case proplists:get_value(help, Opts) of
                true ->
                    usage(standard_io);
                _ ->
                    main(Opts, PosArgs)
            end;
        {error, Reason} ->
            terminate_invalid_args(Reason)
    end.

main(Opts, Args) ->
    setup_logging(Opts),
    ok = io:setopts([binary, {encoding, unicode}]),
    IncludeDirs = proplists:get_all_values(include_dirs, Opts),
    Format = validate_format(proplists:get_value(format, Opts)),
    ParseOpts = #{format => map, include_dirs => IncludeDirs},
    Conf =
        case Args of
            [] ->
                parse_input(slurp_standard_input(), ParseOpts);
            [_ | _] = Filenames ->
                parse_files(Filenames, ParseOpts)
        end,
    ConfFormatted = format_conf(Format, Conf),
    Output = prepare_output(proplists:get_value(output, Opts)),
    write_output(Output, ConfFormatted),
    ok.

parse_input(Stdin, ParseOpts) ->
    case hocon:binary(iolist_to_binary(Stdin), ParseOpts) of
        {ok, Conf} ->
            Conf;
        {error, Reason} ->
            ?STDERR("Parse error: ~p", [Reason]),
            die(3)
    end.

parse_files(Files, ParseOpts) ->
    case hocon:files(Files, ParseOpts) of
        {ok, Conf} ->
            Conf;
        {error, Reason} ->
            ?STDERR("Parse error: ~p", [Reason]),
            die(3)
    end.

setup_logging(_Opts) ->
    logger:set_primary_config(level, critical).

prepare_output("-") ->
    standard_io;
prepare_output(Filename) ->
    case file:open(Filename, [write, binary]) of
        {ok, FD} ->
            FD;
        {error, Reason} ->
            ?STDERR("Invalid output file: ~s", [file:format_error(Reason)]),
            die(2)
    end.

write_output(FD, Bytes) ->
    case write(FD, Bytes) of
        ok when is_atom(FD) ->
            ok;
        ok ->
            file:sync(FD);
        {error, Reason} ->
            ?STDERR("Write error: ~s", [file:format_error(Reason)]),
            die(2)
    end.

write(standard_io, Bytes) ->
    io:put_chars(standard_io, Bytes);
write(FD, Bytes) ->
    file:write(FD, Bytes).

validate_format("json") -> json;
validate_format("yaml") -> yaml;
validate_format(Format) -> terminate_invalid_args({format, Format}).

format_conf(json, Conf) ->
    json:format(Conf);
format_conf(yaml, Conf) ->
    format_yaml(Conf).

slurp_standard_input() ->
    slurp_standard_input([]).

slurp_standard_input(Acc) ->
    case io:get_chars("", 32768) of
        eof ->
            lists:reverse(Acc);
        Data when is_binary(Data) ->
            slurp_standard_input([Data | Acc])
    end.

-spec terminate_invalid_args(term()) -> no_return().
terminate_invalid_args(Reason) ->
    ?STDERR("Invalid arguments: ~p", [Reason]),
    usage(standard_error),
    die(1).

%%--------------------------------------------------------------------
%% YAML formatter
%%--------------------------------------------------------------------

format_yaml(Conf) ->
    yaml_lines(Conf, <<>>).

yaml_lines(#{} = Conf, Indent) when map_size(Conf) > 0 ->
    [yaml_map_entry(Key, Value, Indent) || {Key, Value} <- maps:to_list(Conf)];
yaml_lines([_ | _] = Values, Indent) ->
    [yaml_list_entry(Value, Indent) || Value <- Values];
yaml_lines(Value, Indent) ->
    [Indent, yaml_scalar(Value), $\n].

yaml_map_entry(Key, Value, Indent) ->
    [Indent, yaml_map_entry_content(Key, Value, Indent)].

yaml_map_entry_content(Key, Value, Indent) ->
    case is_nonempty_collection(Value) of
        true ->
            [yaml_key(Key), $:, $\n, yaml_lines(Value, increase_indent(Indent))];
        false ->
            [yaml_key(Key), $:, $\s, yaml_scalar(Value), $\n]
    end.

yaml_list_entry(#{} = Value, IndentBase) when map_size(Value) > 0 ->
    [{K0, V0} | Rest] = maps:to_list(Value),
    Indent = increase_indent(IndentBase),
    [
        IndentBase,
        $-,
        $\s,
        yaml_map_entry_content(K0, V0, Indent),
        [yaml_map_entry(K, V, Indent) || {K, V} <- Rest]
    ];
yaml_list_entry(Value, Indent) ->
    case is_nonempty_collection(Value) of
        true ->
            [Indent, $-, $\n, yaml_lines(Value, increase_indent(Indent))];
        false ->
            [Indent, $-, $\s, yaml_scalar(Value), $\n]
    end.

increase_indent(Indent) ->
    <<Indent/binary, "  ">>.

is_nonempty_collection(#{} = Value) ->
    map_size(Value) > 0;
is_nonempty_collection([_ | _]) ->
    true;
is_nonempty_collection(_) ->
    false.

yaml_scalar(Value) ->
    json:encode(Value).

yaml_key(Key) when is_binary(Key) ->
    case is_plain_key(Key) andalso not is_yaml_keyword(Key) of
        true -> Key;
        false -> yaml_scalar(Key)
    end;
yaml_key(Key) ->
    yaml_scalar(Key).

is_plain_key(Key) ->
    re:run(Key, <<"^[A-Za-z_][A-Za-z0-9_.-]*$">>, [{capture, none}]) =:= match.

is_yaml_keyword(Key) ->
    lists:member(string:lowercase(Key), [
        <<"false">>,
        <<"no">>,
        <<"null">>,
        <<"off">>,
        <<"on">>,
        <<"true">>,
        <<"yes">>
    ]).

-ifndef(TEST).

die(Status) ->
    erlang:halt(Status).

-else.

-include_lib("eunit/include/eunit.hrl").

die(_Status) ->
    ok.

yaml_format_test() ->
    Hocon =
        ~"""
        a_list = [1, true, null, "true", {nested = value, second = 2}]
        empty_list = []
        empty_map = {}
        "needs: quoting" = value
        number = 42
        text = "hello\nworld"
        "true" = key
        unicode = "你我他"
        """,
    {ok, Conf} = hocon:binary(Hocon, #{format => map}),
    Expected =
        ~"""
        a_list:
          - 1
          - true
          - null
          - "true"
          - nested: "value"
            second: 2
        empty_list: []
        empty_map: {}
        "needs: quoting": "value"
        number: 42
        text: "hello\nworld"
        "true": "key"
        unicode: "你我他"

        """,
    ?assertEqual(Expected, iolist_to_binary(format_conf(yaml, Conf))).

json_format_test() ->
    Hocon =
        ~"""
        enabled = true
        name = demo
        nested.count = 2
        """,
    {ok, Conf} = hocon:binary(Hocon, #{format => map}),
    Expected =
        ~"""
        {
          "enabled": true,
          "name": "demo",
          "nested": { "count": 2 }
        }

        """,
    ?assertEqual(Expected, iolist_to_binary(format_conf(json, Conf))).

-endif.
