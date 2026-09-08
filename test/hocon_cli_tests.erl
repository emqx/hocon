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

-module(hocon_cli_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STATUS_SUCCESS, 0).
-define(STATUS_USAGE_ERROR, 1).
-define(STATUS_OUTPUT_ERROR, 2).
-define(STATUS_CONFIG_ERROR, 3).

cli_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(Context) ->
        [
            {"top-level and subcommand help", fun() -> help(Context) end},
            {"format files as HOCON, JSON, and YAML", fun() -> format_files(Context) end},
            {"format stdin as JSON on stdout", fun() -> format_stdin(Context) end},
            {"validate valid and invalid configuration", fun() -> validate(Context) end},
            {"load a schema module", fun() -> schema_module(Context) end},
            {"reject modules invalid schemas", fun() -> invalid_schema_module(Context) end},
            {"merge repeated configuration files", fun() -> repeated_conf_files(Context) end},
            {"get one or more checked values", fun() -> get_values(Context) end},
            {"apply environment overrides through get", fun() -> get_env_override(Context) end},
            {"get nested array and missing values", fun() -> get_nested_values(Context) end},
            {"reject a key with an unknown schema root", fun() -> get_unknown_root(Context) end},
            {"generate application config and VM arguments", fun() -> generate(Context) end},
            {"log environment overrides during generation", fun() ->
                generate_env_override_logging(Context)
            end},
            {"invalid configuration generates no output", fun() -> generate_failure(Context) end},
            {"generate schema documentation", fun() -> docgen(Context) end},
            {"return distinct usage, output, and config errors", fun() -> errors(Context) end}
        ]
    end}.

setup() ->
    Dir = filename:join([
        "_build",
        "test",
        atom_to_list(?MODULE) ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))
    ]),
    Input = filename:join(Dir, "input.conf"),
    InvalidInput = filename:join(Dir, "invalid.conf"),
    InvalidSchema = filename:join(Dir, "not_a_schema.erl"),
    BrokenSchema = filename:join(Dir, "broken_schema.erl"),
    ok = filelib:ensure_dir(Input),
    Hocon =
        ~"""
        enabled = true
        name = demo
        nested.count = 2
        unicode = "你我他"
        """,
    ok = file:write_file(Input, Hocon),
    ok = file:write_file(InvalidInput, <<"foo = {">>),
    ok = file:write_file(
        InvalidSchema,
        ~"""
        -module(not_a_schema).
        -export([hello/0]).

        hello() -> world.
        """
    ),
    ok = file:write_file(
        BrokenSchema,
        ~"""
        -module(broken_schema).
        broken( ->
        """
    ),
    #{
        dir => Dir,
        input => Input,
        invalid_input => InvalidInput,
        invalid_schema => InvalidSchema,
        broken_schema => BrokenSchema,
        hocon => Hocon,
        logger => save_logger_config()
    }.

cleanup(#{dir := Dir, logger := LoggerConfig}) ->
    restore_logger_config(LoggerConfig),
    {ok, Filenames} = file:list_dir(Dir),
    lists:foreach(fun(Filename) -> ok = file:delete(filename:join(Dir, Filename)) end, Filenames),
    ok = file:del_dir(Dir).

help(_Context) ->
    {?STATUS_SUCCESS, Help} = capture(<<>>, fun() -> hocon_cli:run([]) end),
    ?assertNotEqual(nomatch, binary:match(Help, <<"Read, format, validate">>)),
    ?assertNotEqual(nomatch, binary:match(Help, <<"format">>)),
    {?STATUS_SUCCESS, FormatHelp} = capture(<<>>, fun() ->
        hocon_cli:run(["help", "format"])
    end),
    ?assertNotEqual(nomatch, binary:match(FormatHelp, <<"Format HOCON as HOCON, JSON, or YAML">>)).

format_files(#{dir := Dir, input := Input}) ->
    HoconOutput = filename:join(Dir, "output.hocon"),
    JSONOutput = filename:join(Dir, "output.json"),
    YAMLOutput = filename:join(Dir, "output.yaml"),
    ?assertEqual(?STATUS_SUCCESS, run_format(hocon, Input, HoconOutput)),
    ?assertEqual(?STATUS_SUCCESS, run_format(json, Input, JSONOutput)),
    ?assertEqual(?STATUS_SUCCESS, run_format(yaml, Input, YAMLOutput)),
    {ok, Expected} = hocon:load(Input),
    {ok, ActualHocon} = hocon:load(HoconOutput),
    {ok, JSON} = file:read_file(JSONOutput),
    {ok, YAML} = file:read_file(YAMLOutput),
    ?assertEqual(Expected, ActualHocon),
    ?assertEqual(Expected, json:decode(JSON)),
    ?assertEqual(
        ~"""
        enabled: true
        name: "demo"
        nested:
          count: 2
        unicode: "你我他"

        """,
        YAML
    ).

format_stdin(#{hocon := Hocon}) ->
    Expected = #{
        <<"enabled">> => true,
        <<"name">> => <<"demo">>,
        <<"nested">> => #{<<"count">> => 2},
        <<"unicode">> => <<"你我他"/utf8>>
    },
    lists:foreach(
        fun(Args) ->
            {?STATUS_SUCCESS, JSON} = capture(Hocon, fun() -> hocon_cli:run(Args) end),
            ?assertEqual(Expected, json:decode(JSON))
        end,
        [
            ["format", "--format", "json"],
            ["format", "--format", "json", "--output=-", "-"],
            ["format", "-", "--format", "json"]
        ]
    ).

validate(_Context) ->
    ?assertEqual(
        ?STATUS_SUCCESS,
        hocon_cli:run([
            "validate",
            "--log-level",
            "emergency",
            "--schema-file",
            schema_file(),
            "--conf-file",
            config_file("demo-schema-example-1.conf")
        ])
    ),
    ?assertEqual(
        ?STATUS_CONFIG_ERROR,
        hocon_cli:run([
            "validate",
            "--log-level",
            "emergency",
            "--schema-file",
            schema_file(),
            "--conf-file",
            config_file("demo-schema-failure.conf")
        ])
    ),
    Envs = [
        {"HOCON_ENV_OVERRIDE_PREFIX", "HOCON_CLI_TEST_"},
        {"HOCON_CLI_TEST_FOO__MIN", "2"}
    ],
    {Status, Output} = capture(<<>>, fun() ->
        hocon_test_lib:with_envs(
            fun() ->
                hocon_cli:run([
                    "validate",
                    "--log-env-overrides",
                    "--schema-file",
                    schema_file(),
                    "--conf-file",
                    config_file("demo-schema-example-1.conf")
                ])
            end,
            Envs
        )
    end),
    ?assertEqual(?STATUS_SUCCESS, Status),
    ?assertEqual(<<"HOCON_CLI_TEST_FOO__MIN [foo.min]: 2\n">>, Output).

schema_module(_Context) ->
    ?assertEqual(
        ?STATUS_SUCCESS,
        hocon_cli:run([
            "validate",
            "--schema-module",
            "demo_schema",
            "--conf-file",
            config_file("demo-schema-example-1.conf")
        ])
    ).

invalid_schema_module(#{dir := Dir, invalid_schema := InvalidSchema}) ->
    InvalidModuleArgs = ["--log-level", "emergency", "--schema-module", "erlang"],
    Commands = [
        ["get" | InvalidModuleArgs ++ ["foo"]],
        ["validate" | InvalidModuleArgs],
        ["docgen" | InvalidModuleArgs],
        [
            "generate"
            | InvalidModuleArgs ++
                [
                    "--out-app-config",
                    filename:join(Dir, "invalid-schema-app.config"),
                    "--out-vm-args",
                    filename:join(Dir, "invalid-schema-vm.args")
                ]
        ]
    ],
    lists:foreach(
        fun(Args) -> ?assertEqual(?STATUS_CONFIG_ERROR, hocon_cli:run(Args)) end,
        Commands
    ),
    ?assertEqual(
        ?STATUS_CONFIG_ERROR,
        hocon_cli:run([
            "validate",
            "--log-level",
            "emergency",
            "--schema-file",
            InvalidSchema
        ])
    ).

repeated_conf_files(_Context) ->
    {Status, Output} = capture(<<>>, fun() ->
        hocon_cli:run([
            "get",
            "--schema-file",
            schema_file(),
            "--conf-file",
            config_file("demo-schema-example-2.conf"),
            "--conf-file",
            config_file("demo-schema-example-3.conf"),
            "foo.setting"
        ])
    end),
    ?assertEqual(?STATUS_SUCCESS, Status),
    ?assertEqual(<<"yaa\n">>, Output).

get_values(_Context) ->
    Args = [
        "get",
        "--schema-file",
        schema_file(),
        "--conf-file",
        config_file("demo-schema-example-1.conf")
    ],
    {?STATUS_SUCCESS, One} = capture(<<>>, fun() ->
        hocon_cli:run(Args ++ ["foo.setting"])
    end),
    ?assertEqual(<<"hello\n">>, One),
    {?STATUS_SUCCESS, Many} = capture(<<>>, fun() ->
        hocon_cli:run(Args ++ ["foo.min", "foo.max"])
    end),
    ?assertEqual(<<"foo.min=1\nfoo.max=10\n">>, Many),
    EndpointArgs = ["get", "--schema-file", schema_file(), "foo.endpoint"],
    {?STATUS_SUCCESS, Endpoint} = capture(<<"foo.endpoint = \"127.0.0.1\"\n">>, fun() ->
        hocon_cli:run(EndpointArgs)
    end),
    ?assertEqual(<<"\"127.0.0.1\"\n">>, Endpoint).

get_env_override(_Context) ->
    Args = [
        "get",
        "-l",
        "info",
        "--schema-file",
        schema_file(),
        "--conf-file",
        config_file("demo-schema-example-2.conf"),
        "foo.setting"
    ],
    Envs = [
        {"HOCON_ENV_OVERRIDE_PREFIX", "HOCON_CLI_TEST_"},
        {"HOCON_CLI_TEST_FOO__MIN", "42"},
        {"HOCON_CLI_TEST_FOO__SETTING", "hi"}
    ],
    {Status, Output} = capture(<<>>, fun() ->
        hocon_test_lib:with_envs(fun() -> hocon_cli:run(Args) end, Envs)
    end),
    ?assertEqual(?STATUS_SUCCESS, Status),
    ?assertEqual(<<"hi\n">>, Output).

get_nested_values(_Context) ->
    {Status, Output} = capture(<<>>, fun() ->
        hocon_cli:run([
            "get",
            "--schema-file",
            filename:join("sample-schemas", "demo_schema2.erl"),
            "--conf-file",
            config_file("demo_schema2.conf"),
            "foo.1.int",
            "foo.x.int",
            "foo.9.int",
            "foo.0.int"
        ])
    end),
    ?assertEqual(?STATUS_SUCCESS, Status),
    ?assertEqual(
        <<
            "foo.1.int=1\n"
            "foo.x.int=undefined\n"
            "foo.9.int=undefined\n"
            "foo.0.int=undefined\n"
        >>,
        Output
    ).

get_unknown_root(_Context) ->
    ?assertEqual(
        ?STATUS_CONFIG_ERROR,
        hocon_cli:run([
            "get",
            "--log-level",
            "emergency",
            "--schema-file",
            schema_file(),
            "--conf-file",
            config_file("demo-schema-example-1.conf"),
            "bla"
        ])
    ).

generate(#{dir := Dir}) ->
    AppConfig = filename:join(Dir, "app.config"),
    VMArgs = filename:join(Dir, "vm.args"),
    ?assertEqual(
        ?STATUS_SUCCESS,
        hocon_cli:run([
            "generate",
            "--schema-file",
            schema_file(),
            "--conf-file",
            config_file("demo-schema-example-2.conf"),
            "--out-app-config",
            AppConfig,
            "--out-vm-args",
            VMArgs
        ])
    ),
    {ok, [[{app_foo, AppFoo}]]} = file:consult(AppConfig),
    ?assertEqual({1, 10}, proplists:get_value(range, AppFoo)),
    ?assertEqual("hello", proplists:get_value(setting, AppFoo)),
    ?assertEqual(
        <<"-env ERL_MAX_PORTS 64000\n-name emqx@127.0.0.1">>,
        element(2, file:read_file(VMArgs))
    ).

generate_env_override_logging(#{dir := Dir}) ->
    AppConfig = filename:join(Dir, "env-app.config"),
    VMArgs = filename:join(Dir, "env-vm.args"),
    Args = [
        "generate",
        "--log-env-overrides",
        "--schema-file",
        schema_file(),
        "--conf-file",
        config_file("demo-schema-example-2.conf"),
        "--out-app-config",
        AppConfig,
        "--out-vm-args",
        VMArgs
    ],
    Envs = [
        {"HOCON_ENV_OVERRIDE_PREFIX", "HOCON_CLI_TEST_"},
        {"HOCON_CLI_TEST_FOO__MIN", "2"},
        {"HOCON_CLI_TEST_FOO__SETTING", "hi"}
    ],
    {Status, Output} = capture(<<>>, fun() ->
        hocon_test_lib:with_envs(fun() -> hocon_cli:run(Args) end, Envs)
    end),
    ?assertEqual(?STATUS_SUCCESS, Status),
    ?assertNotEqual(
        nomatch,
        binary:match(Output, <<"HOCON_CLI_TEST_FOO__MIN [foo.min]: 2">>)
    ),
    ?assertNotEqual(
        nomatch,
        binary:match(Output, <<"HOCON_CLI_TEST_FOO__SETTING [foo.setting]: ******">>)
    ),
    ?assertEqual(nomatch, binary:match(Output, <<"[info]">>)),
    {ok, [[{app_foo, AppFoo}]]} = file:consult(AppConfig),
    ?assertEqual({2, 10}, proplists:get_value(range, AppFoo)),
    ?assertEqual("hi", proplists:get_value(setting, AppFoo)),
    ?assertMatch({ok, _}, file:read_file(VMArgs)).

generate_failure(#{dir := Dir}) ->
    AppConfig = filename:join(Dir, "invalid-app.config"),
    VMArgs = filename:join(Dir, "invalid-vm.args"),
    ?assertEqual(
        ?STATUS_CONFIG_ERROR,
        hocon_cli:run([
            "generate",
            "--log-level",
            "emergency",
            "--schema-file",
            schema_file(),
            "--conf-file",
            config_file("demo-schema-failure.conf"),
            "--out-app-config",
            AppConfig,
            "--out-vm-args",
            VMArgs
        ])
    ),
    ?assertEqual({error, enoent}, file:read_file(AppConfig)),
    ?assertEqual({error, enoent}, file:read_file(VMArgs)).

docgen(_Context) ->
    {?STATUS_SUCCESS, Markdown} = capture(<<>>, fun() ->
        hocon_cli:run(["docgen", "--schema-file", schema_file(), "--doctitle", "Demo"])
    end),
    ?assertMatch(<<"Demo\n", _/binary>>, Markdown),
    ?assertNotEqual(nomatch, binary:match(Markdown, <<"foo">>)).

errors(#{dir := Dir, input := Input, invalid_input := InvalidInput}) ->
    ?assertEqual(?STATUS_USAGE_ERROR, hocon_cli:run(["format", Input, "-"])),
    ?assertEqual(
        ?STATUS_CONFIG_ERROR,
        hocon_cli:run(["validate", "--pa", filename:join(Dir, "missing-code-path")])
    ),
    ?assertEqual(
        ?STATUS_OUTPUT_ERROR,
        hocon_cli:run([
            "format",
            "--log-level",
            "emergency",
            "--output",
            filename:join([Dir, "missing", "output.conf"]),
            Input
        ])
    ),
    ?assertEqual(
        ?STATUS_CONFIG_ERROR,
        hocon_cli:run(["format", "--log-level", "emergency", InvalidInput])
    ).

run_format(Format, Input, Output) ->
    hocon_cli:run([
        "format",
        "--format",
        atom_to_list(Format),
        "--output",
        Output,
        Input
    ]).

schema_file() ->
    filename:join("sample-schemas", "demo_schema.erl").

config_file(Filename) ->
    filename:join("etc", Filename).

capture(Input, Fun) ->
    GroupLeader = group_leader(),
    Stderr = whereis(standard_error),
    IOCapture = spawn_link(fun() -> io_loop(iolist_to_binary(Input), queue:new()) end),
    true = group_leader(IOCapture, self()),
    true = unregister(standard_error),
    true = register(standard_error, IOCapture),
    try
        Result = Fun(),
        hocon_cli:sync_logger(),
        Ref = make_ref(),
        IOCapture ! {get_output, self(), Ref},
        receive
            {Ref, Output} -> {Result, iolist_to_binary(Output)}
        after 1000 ->
            error(io_capture_timeout)
        end
    after
        true = unregister(standard_error),
        true = register(standard_error, Stderr),
        true = group_leader(GroupLeader, self()),
        unlink(IOCapture),
        IOCapture ! stop
    end.

io_loop(Input, Output) ->
    receive
        {io_request, From, ReplyAs, Request} ->
            {Reply, Rest, NewOutput} = io_request(Request, Input, Output),
            From ! {io_reply, ReplyAs, Reply},
            io_loop(Rest, NewOutput);
        {get_output, From, Ref} ->
            From ! {Ref, queue:to_list(Output)},
            io_loop(Input, Output);
        stop ->
            ok
    end.

io_request({put_chars, Chars}, Input, Output) ->
    {ok, Input, queue:in(Chars, Output)};
io_request({put_chars, _Encoding, Chars}, Input, Output) ->
    io_request({put_chars, Chars}, Input, Output);
io_request({put_chars, Module, Function, Args}, Input, Output) ->
    io_request({put_chars, apply(Module, Function, Args)}, Input, Output);
io_request({put_chars, _Encoding, Module, Function, Args}, Input, Output) ->
    io_request({put_chars, Module, Function, Args}, Input, Output);
io_request({get_chars, _Prompt, Count}, Input, Output) ->
    get_chars(Count, Input, Output);
io_request({get_chars, _Encoding, _Prompt, Count}, Input, Output) ->
    get_chars(Count, Input, Output);
io_request({requests, Requests}, Input, Output) ->
    io_requests(Requests, Input, Output);
io_request({setopts, _Options}, Input, Output) ->
    {ok, Input, Output};
io_request(getopts, Input, Output) ->
    {{ok, [{encoding, unicode}]}, Input, Output}.

io_requests([], Input, Output) ->
    {ok, Input, Output};
io_requests([Request | Rest], Input0, Output0) ->
    case io_request(Request, Input0, Output0) of
        {ok, Input, Output} -> io_requests(Rest, Input, Output);
        Result -> Result
    end.

get_chars(_Count, <<>>, Output) ->
    {eof, <<>>, Output};
get_chars(Count, Input, Output) when byte_size(Input) =< Count ->
    {Input, <<>>, Output};
get_chars(Count, Input, Output) ->
    <<Chars:Count/binary, Rest/binary>> = Input,
    {Chars, Rest, Output}.

save_logger_config() ->
    #{
        primary => logger:get_primary_config(),
        default => logger:get_handler_config(default),
        cli => logger:get_handler_config(hocon_cli)
    }.

restore_logger_config(#{primary := Primary, default := Default, cli := CLI}) ->
    _ = logger:remove_handler(default),
    _ = logger:remove_handler(hocon_cli),
    restore_logger_handler(default, Default),
    restore_logger_handler(hocon_cli, CLI),
    ok = logger:set_primary_config(Primary).

restore_logger_handler(_Id, {error, _Reason}) ->
    ok;
restore_logger_handler(Id, {ok, #{module := Module} = Config}) ->
    ok = logger:add_handler(Id, Module, maps:without([id, module], Config)).
