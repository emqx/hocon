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

-module(hocon_cli_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

-define(assertPrinted(___Text),
    (fun() ->
        case cuttlefish_test_group_leader:get_output() of
            {ok, ___Output} ->
                case re:run(___Output, ___Text) of
                    {match, _} ->
                        ok;
                    nomatch ->
                        erlang:error(
                            {assertPrinted_failed, [
                                {module, ?MODULE},
                                {line, ?LINE},
                                {expected, ___Text},
                                {actual, unicode:characters_to_list(___Output)}
                            ]}
                        )
                end;
            error ->
                erlang:error(
                    {assertPrinted_failed, [
                        {module, ?MODULE},
                        {line, ?LINE},
                        {expected, ___Text},
                        {reason, timed_out_on_receive}
                    ]}
                )
        end
    end)()
).

-define(CAPTURING(__Forms),
    (fun() ->
        ___OldLeader = group_leader(),
        group_leader(cuttlefish_test_group_leader:new_group_leader(self()), self()),
        try
            __Forms
        after
            cuttlefish_test_group_leader:tidy_up(___OldLeader)
        end
    end)()
).

generate_config_test_() ->
    Output = [{app_foo, [{range, {1, 10}}, {setting, "hello"}]}],
    Gen = fun(T, Sc) ->
        hocon_cli:main(
            ["-c", etc("demo-schema-example-1.conf")] ++
                generate_opts(T) ++ Sc
        )
    end,
    [
        fun() ->
            [$2 | Time0] = now_time(),
            Time = [$3 | Time0],
            Gen(Time, ["-i", ss("demo_schema.erl")]),
            {ok, Config} = file:consult(config_fname(Time)),
            ?assertEqual(Output, hd(Config))
        end,
        fun() ->
            Time = now_time(),
            Gen(Time, ["-s", "demo_schema"]),
            {ok, Config} = file:consult(config_fname(Time)),
            ?assertEqual(Output, hd(Config))
        end
    ].

generate_config_failure_test() ->
    Gen = fun(T, Sc) ->
        hocon_cli:main(
            ["-c", etc("demo-schema-failure.conf")] ++
                generate_opts(T) ++ Sc
        )
    end,
    Time = now_time(),
    %% not demo_schema, so the check will fail
    SchemaModule = "demo_schema",
    ?assertThrow(stop_deactivate, Gen(Time, ["-s", SchemaModule])).

generate_multiple_input_config_test() ->
    Time = now_time(),
    hocon_cli:main(
        [
            "-s",
            "demo_schema",
            "-c",
            etc("demo-schema-example-2.conf"),
            "-c",
            etc("demo-schema-example-3.conf")
        ] ++ generate_opts(Time)
    ),
    {ok, [[{app_foo, Plist}]]} = file:consult(config_fname(Time)),
    ?assertEqual("yaa", proplists:get_value(setting, Plist)).

generate_opts(T) -> ["-t", T, "-d", out(), "generate"].

generate_with_schema_opts(Time, MaxHistory, Dir) ->
    generate_with_schema_opts(Time, MaxHistory, Dir, []).

generate_with_schema_opts(Time, MaxHistory, Dir, ExtraOpts) ->
    [
        "-c",
        etc("demo-schema-example-1.conf"),
        "-s",
        "demo_schema",
        "-t",
        Time,
        "-m",
        integer_to_list(MaxHistory),
        "-d",
        Dir
    ] ++ ExtraOpts ++ ["generate"].

now_time_test() ->
    ?CAPTURING(begin
        hocon_cli:main(["now_time"]),
        {ok, Stdout} = cuttlefish_test_group_leader:get_output(),
        ?assert(hocon_cli:is_valid_now_time(Stdout))
    end).

generate_with_env_logging_test() ->
    Envs = [
        {"ZZZ_FOO", "{min: 1, max: 2}"},
        {"ZZZ_FOO__MIN", "42"},
        {"ZZZ_FOO__MAX", "43"},
        {"ZZZ_FOO__NUMBERS", "[1,2]"},
        {"HOCON_ENV_OVERRIDE_PREFIX", "ZZZ_"}
    ],
    Expects = [
        <<"ZZZ_FOO [foo]: {...}">>,
        <<"ZZZ_FOO__MAX [foo.max]: 43">>,
        <<"ZZZ_FOO__MIN [foo.min]: 42">>,
        <<"ZZZ_FOO__NUMBERS [foo.numbers]: [...]">>
    ],
    test_generate_with_env_logging(Envs, Expects).

generate_with_env_logging_empty_array_test() ->
    Envs = [
        {"ZZZ_FOO__NUMBERS", "[]"},
        {"HOCON_ENV_OVERRIDE_PREFIX", "ZZZ_"}
    ],
    Expects = [
        <<"ZZZ_FOO__NUMBERS [foo.numbers]: []">>
    ],
    test_generate_with_env_logging(Envs, Expects).

test_generate_with_env_logging(Envs, Expects) ->
    ?CAPTURING(begin
        Time = now_time(),
        with_envs(
            fun hocon_cli:main/1,
            [
                [
                    "-c",
                    etc("demo-schema-example-1.conf"),
                    "-s",
                    "demo_schema",
                    "-t",
                    Time,
                    "-d",
                    out(),
                    "--verbose_env",
                    "generate"
                ]
            ],
            Envs
        ),
        {ok, Stdout} = cuttlefish_test_group_leader:get_output(),
        ?assertEqual(
            Expects,
            lists:sort(
                binary:split(
                    iolist_to_binary(Stdout),
                    <<"\n">>,
                    [global, trim]
                )
            )
        )
    end).

generate_vmargs_test() ->
    ?CAPTURING(begin
        Time = now_time(),
        hocon_cli:main([
            "-c",
            etc("demo-schema-example-2.conf"),
            "-t",
            Time,
            "-d",
            out(),
            "-s",
            "demo_schema",
            "generate"
        ]),
        {ok, Config} = file:read_file(vmargs_fname(Time)),
        ?assertEqual(<<"-env ERL_MAX_PORTS 64000\n-name emqx@127.0.0.1">>, Config)
    end).

get_test_() ->
    [
        {"`get` output is correct", fun get_basic/0},
        {"`get` respect env var", fun get_env/0},
        {"`multi_get` values", fun get_multi/0},
        {"`get` command tests", fun get_help/0},
        {"`multi_get` command tests", fun multi_get_help/0}
    ].

get_help() ->
    ?CAPTURING(begin
        catch hocon_cli:main(["-c", "foo", "-s", "bar", "get"]),
        ?assertPrinted("HOCON 'get' command")
    end).

multi_get_help() ->
    ?CAPTURING(begin
        catch hocon_cli:main(["-c", "foo", "-s", "bar", "multi_get"]),
        ?assertPrinted("HOCON 'multi_get' command")
    end).

get_basic() ->
    ?CAPTURING(begin
        hocon_cli:main([
            "-c",
            etc("demo-schema-example-1.conf"),
            "-s",
            "demo_schema",
            "get",
            "foo.setting"
        ]),
        ?assertPrinted("\"hello\"")
    end).

get_multi() ->
    ?CAPTURING(begin
        hocon_cli:main([
            "-c",
            etc("demo-schema-example-1.conf"),
            "-s",
            "demo_schema",
            "multi_get",
            "foo.min",
            "foo.max",
            "a_b"
        ]),
        ?assertPrinted("foo.min=1\nfoo.max=10\na_b=undefined\n")
    end).

get_env() ->
    ?CAPTURING(begin
        with_envs(
            fun hocon_cli:main/1,
            [
                [
                    "-c",
                    etc("demo-schema-example-2.conf"),
                    "-s",
                    "demo_schema",
                    "get",
                    "foo.setting"
                ]
            ],
            [
                {"EMQX_FOO__SETTING", "hi"},
                {"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}
            ]
        ),
        ?assertPrinted("\"hi\"")
    end).

get_array_test() ->
    ?CAPTURING(begin
        hocon_cli:main([
            "-c",
            etc("demo_schema2.conf"),
            "-s",
            "demo_schema2",
            "get",
            "foo.1.int"
        ]),
        ?assertPrinted("1\n")
    end).

get_array_fail_test() ->
    ?CAPTURING(begin
        hocon_cli:main([
            "-c",
            etc("demo_schema2.conf"),
            "-s",
            "demo_schema2",
            "get",
            "foo.x.int"
        ]),
        ?assertPrinted("undefined\n")
    end).

prune_test() ->
    GenDir = out(),
    case file:list_dir(out()) of
        {ok, FilenamesToDelete} ->
            [file:delete(filename:join([GenDir, F])) || F <- FilenamesToDelete];
        _ ->
            ok
    end,

    ExpectedMax = 2,

    Cli = fun() ->
        hocon_cli:main([
            "-i",
            ss("demo_schema.erl"),
            "-c",
            etc("demo-schema-example-1.conf"),
            "--now_time",
            now_time(),
            "-m",
            integer_to_list(ExpectedMax),
            "-d",
            out()
        ])
    end,
    Cli(),
    %% Timer to keep from generating more than one file per second
    timer:sleep(1100),
    Cli(),
    timer:sleep(1100),
    Cli(),
    AppConfigs = lists:sort(filelib:wildcard("app.*.config", out())),
    VMArgs = lists:sort(filelib:wildcard("vm.*.args", out())),
    ?assertEqual(2, length(AppConfigs)),
    ?assertEqual(2, length(VMArgs)),

    timer:sleep(1100),
    Cli(),
    NewAppConfigs = lists:sort(filelib:wildcard("app.*.config", out())),
    % check if old one has been deleted, not new one
    ?assertEqual(lists:nth(1, NewAppConfigs), lists:nth(2, AppConfigs)).

generation_with_older_timestamp_keeps_current_files_test() ->
    Dir = filename:join(out(), atom_to_list(?FUNCTION_NAME)),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    CurrentTime = "2000.01.01.00.00.00",
    ExistingTimes = ["2000.01.01.00.00.01", "2000.01.01.00.00.02"],
    ExistingFiles =
        [
            filename:join(Dir, Prefix ++ "." ++ Time ++ "." ++ Extension)
         || {Prefix, Extension} <- [{"app", "config"}, {"vm", "args"}],
            Time <- ExistingTimes
        ],
    lists:foreach(fun(Filename) -> ok = file:write_file(Filename, <<"old">>) end, ExistingFiles),
    CurrentAppConfig = filename:join(Dir, "app." ++ CurrentTime ++ ".config"),
    CurrentVMArgs = filename:join(Dir, "vm." ++ CurrentTime ++ ".args"),
    try
        ok = hocon_cli:main(generate_with_schema_opts(CurrentTime, 2, Dir)),
        ?assert(filelib:is_regular(CurrentAppConfig)),
        ?assert(filelib:is_regular(CurrentVMArgs)),
        ?assertEqual(
            lists:sort([
                CurrentAppConfig,
                filename:join(Dir, "app.2000.01.01.00.00.02.config")
            ]),
            lists:sort(filelib:wildcard(filename:join(Dir, "app.*.config")))
        ),
        ?assertEqual(
            lists:sort([
                CurrentVMArgs,
                filename:join(Dir, "vm.2000.01.01.00.00.02.args")
            ]),
            lists:sort(filelib:wildcard(filename:join(Dir, "vm.*.args")))
        )
    after
        cleanup_dir(Dir)
    end.

generation_prunes_only_matching_dest_file_test() ->
    Dir = filename:join(out(), atom_to_list(?FUNCTION_NAME)),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    OldCustomConfig = filename:join(Dir, "app.custom.1999.01.01.00.00.00.config"),
    OtherConfig = filename:join(Dir, "app.other.1999.01.01.00.00.00.config"),
    ManualConfig = filename:join(Dir, "app.manual.config"),
    OtherTmp = OtherConfig ++ ".123.1.tmp",
    ManualTmp = filename:join(Dir, "app.custom.1999.01.01.00.00.00.config.backup.manual.tmp"),
    UnrelatedFiles = [OldCustomConfig, OtherConfig, ManualConfig] ++ [OtherTmp, ManualTmp],
    lists:foreach(
        fun(Filename) -> ok = file:write_file(Filename, <<"unrelated">>) end,
        UnrelatedFiles
    ),
    StaleMTime = erlang:system_time(second) - 3601,
    ok = set_mtimes([OtherTmp, ManualTmp], StaleMTime),
    try
        ok = hocon_cli:main(
            generate_with_schema_opts(
                "2000.01.01.00.00.01",
                1,
                Dir,
                ["-f", "app.custom"]
            )
        ),
        ?assertNot(filelib:is_file(OldCustomConfig)),
        ?assert(filelib:is_regular(OtherConfig)),
        ?assert(filelib:is_regular(ManualConfig)),
        ?assert(filelib:is_regular(OtherTmp)),
        ?assert(filelib:is_regular(ManualTmp)),
        ?assert(
            filelib:is_regular(
                filename:join(Dir, "app.custom.2000.01.01.00.00.01.config")
            )
        )
    after
        cleanup_dir(Dir)
    end.

stale_tmp_files_are_cleaned_before_generation_test() ->
    Dir = filename:join(out(), atom_to_list(?FUNCTION_NAME)),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    StaleAppTmp = filename:join(Dir, "app.2000.01.01.00.00.00.config.123.1.tmp"),
    StaleVMArgsTmp = filename:join(Dir, "vm.2000.01.01.00.00.00.args.123.2.tmp"),
    FreshAppTmp = filename:join(Dir, "app.2000.01.01.00.00.00.config.456.3.tmp"),
    lists:foreach(
        fun(Filename) -> ok = file:write_file(Filename, <<"tmp">>) end,
        [StaleAppTmp, StaleVMArgsTmp, FreshAppTmp]
    ),
    StaleMTime = erlang:system_time(second) - 3601,
    ok = set_mtimes([StaleAppTmp, StaleVMArgsTmp], StaleMTime),
    try
        ok = hocon_cli:main([
            "-c",
            etc("demo-schema-example-1.conf"),
            "-s",
            "demo_schema",
            "-t",
            "2000.01.01.00.00.01",
            "-d",
            Dir,
            "generate"
        ]),
        ?assertNot(filelib:is_file(StaleAppTmp)),
        ?assertNot(filelib:is_file(StaleVMArgsTmp)),
        ?assert(filelib:is_regular(FreshAppTmp))
    after
        cleanup_dir(Dir)
    end.

cleanup_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:foreach(fun(Filename) -> file:delete(filename:join(Dir, Filename)) end, Files);
        {error, enoent} ->
            ok
    end,
    file:del_dir(Dir),
    ok.

set_mtime(Filename, MTime) ->
    file:write_file_info(Filename, #file_info{mtime = MTime}, [{time, posix}]).

set_mtimes(Filenames, MTime) ->
    lists:foreach(fun(Filename) -> ok = set_mtime(Filename, MTime) end, Filenames).

restore_backup_failure_preserves_target_test() ->
    Dir = filename:join(out(), atom_to_list(?FUNCTION_NAME)),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    Target = filename:join(Dir, "app.config"),
    MissingBackup = filename:join(Dir, "missing.tmp"),
    ok = file:write_file(Target, <<"current">>),
    try
        ok = hocon_cli:restore_backup(Target, MissingBackup),
        ?assertEqual({ok, <<"current">>}, file:read_file(Target))
    after
        cleanup_dir(Dir)
    end.

atomic_write_preserves_existing_modes_test() ->
    Dir = filename:join(out(), atom_to_list(?FUNCTION_NAME)),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    AppConfig = filename:join(Dir, "app.config"),
    VMArgs = filename:join(Dir, "vm.args"),
    lists:foreach(
        fun(Filename) ->
            ok = file:write_file(Filename, <<"old">>),
            ok = file:change_mode(Filename, 8#600)
        end,
        [AppConfig, VMArgs]
    ),
    try
        ?assertEqual(
            ok,
            hocon_cli:atomic_write_files(
                new_config_files(VMArgs, AppConfig),
                fun file:rename/2
            )
        ),
        ?assertEqual({ok, <<"new app config">>}, file:read_file(AppConfig)),
        ?assertEqual({ok, <<"new vm args">>}, file:read_file(VMArgs)),
        ?assertEqual(8#600, file_mode(AppConfig)),
        ?assertEqual(8#600, file_mode(VMArgs))
    after
        cleanup_dir(Dir)
    end.

atomic_prepare_failure_preserves_targets_test() ->
    Dir = filename:join(out(), atom_to_list(?FUNCTION_NAME)),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    VMArgs = filename:join(Dir, "vm.args"),
    AppConfig = filename:join(Dir, "app.config"),
    ok = file:write_file(VMArgs, <<"old vm args">>),
    ok = file:make_dir(AppConfig),
    try
        ?assertEqual(
            {error, AppConfig, eisdir},
            hocon_cli:atomic_write_files(
                new_config_files(VMArgs, AppConfig),
                fun file:rename/2
            )
        ),
        ?assertEqual({ok, <<"old vm args">>}, file:read_file(VMArgs)),
        ?assert(filelib:is_dir(AppConfig)),
        ?assertEqual([], filelib:wildcard(filename:join(Dir, "*.tmp")))
    after
        _ = file:delete(VMArgs),
        _ = file:del_dir(AppConfig),
        _ = file:del_dir(Dir)
    end.

file_mode(Filename) ->
    {ok, #file_info{mode = Mode}} = file:read_file_info(Filename),
    Mode band 8#777.

generation_failure_preserves_retained_history_test() ->
    Dir = filename:join(out(), atom_to_list(?FUNCTION_NAME)),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    OldestTime = "2000.01.01.00.00.00",
    RetainedTime = "2000.01.01.00.00.01",
    NewTime = "2000.01.01.00.00.02",
    OldestAppConfig = filename:join(Dir, "app." ++ OldestTime ++ ".config"),
    OldestVMArgs = filename:join(Dir, "vm." ++ OldestTime ++ ".args"),
    RetainedAppConfig = filename:join(Dir, "app." ++ RetainedTime ++ ".config"),
    RetainedVMArgs = filename:join(Dir, "vm." ++ RetainedTime ++ ".args"),
    NewAppConfig = filename:join(Dir, "app." ++ NewTime ++ ".config"),
    NewVMArgs = filename:join(Dir, "vm." ++ NewTime ++ ".args"),
    lists:foreach(
        fun(Filename) -> ok = file:write_file(Filename, <<"old">>) end,
        [OldestAppConfig, OldestVMArgs, RetainedAppConfig, RetainedVMArgs]
    ),
    ok = file:make_dir(NewVMArgs),
    try
        ?assertThrow(
            stop_deactivate,
            hocon_cli:main(generate_with_schema_opts(NewTime, 2, Dir))
        ),
        ?assertNot(filelib:is_file(OldestAppConfig)),
        ?assertNot(filelib:is_file(OldestVMArgs)),
        ?assert(filelib:is_regular(RetainedAppConfig)),
        ?assert(filelib:is_regular(RetainedVMArgs)),
        ?assertNot(filelib:is_file(NewAppConfig)),
        ?assert(filelib:is_dir(NewVMArgs)),
        ?assertEqual([], filelib:wildcard(filename:join(Dir, "*.tmp")))
    after
        _ = file:delete(OldestAppConfig),
        _ = file:delete(OldestVMArgs),
        _ = file:delete(RetainedAppConfig),
        _ = file:delete(RetainedVMArgs),
        _ = file:delete(NewAppConfig),
        _ = file:del_dir(NewVMArgs),
        _ = file:del_dir(Dir)
    end.

atomic_commit_failure_removes_partial_generation_test() ->
    atomic_commit_failure_test(?FUNCTION_NAME, {error, enoent}, {error, enoent}).

atomic_commit_failure_restores_existing_targets_test() ->
    atomic_commit_failure_test(
        ?FUNCTION_NAME,
        {ok, <<"old app config">>},
        {ok, <<"old vm args">>}
    ).

atomic_commit_failure_test(TestName, ExpectedAppConfig, ExpectedVMArgs) ->
    Dir = filename:join(out(), atom_to_list(TestName)),
    ok = filelib:ensure_dir(filename:join(Dir, "dummy")),
    AppConfig = filename:join(Dir, "app.config"),
    VMArgs = filename:join(Dir, "vm.args"),
    ok = maybe_write_file(AppConfig, ExpectedAppConfig),
    ok = maybe_write_file(VMArgs, ExpectedVMArgs),
    RenameCountKey = {?MODULE, TestName},
    try
        ?assertEqual(
            {error, AppConfig, eacces},
            hocon_cli:atomic_write_files(
                new_config_files(VMArgs, AppConfig),
                fail_second_rename(RenameCountKey)
            )
        ),
        ?assertEqual(ExpectedAppConfig, file:read_file(AppConfig)),
        ?assertEqual(ExpectedVMArgs, file:read_file(VMArgs)),
        ?assertEqual([], filelib:wildcard(filename:join(Dir, "*.tmp")))
    after
        erlang:erase(RenameCountKey),
        _ = file:delete(AppConfig),
        _ = file:delete(VMArgs),
        _ = file:del_dir(Dir)
    end.

new_config_files(VMArgs, AppConfig) ->
    [{VMArgs, <<"new vm args">>}, {AppConfig, <<"new app config">>}].

maybe_write_file(Filename, {ok, Content}) ->
    file:write_file(Filename, Content);
maybe_write_file(_Filename, {error, enoent}) ->
    ok.

fail_second_rename(RenameCountKey) ->
    fun(From, To) ->
        case erlang:get(RenameCountKey) of
            undefined ->
                erlang:put(RenameCountKey, 1),
                file:rename(From, To);
            1 ->
                {error, eacces}
        end
    end.

%% etc-path
etc(Name) ->
    filename:join(["etc", Name]).

%% sample-schemas-path
ss(Name) ->
    filename:join(["sample-schemas", Name]).

%% output
out() ->
    "generated".

config_fname(TimeStr) ->
    filename:join([out(), "app." ++ TimeStr ++ ".config"]).

vmargs_fname(TimeStr) ->
    filename:join([out(), "vm." ++ TimeStr ++ ".args"]).

with_envs(Fun, Args, Envs) ->
    hocon_test_lib:with_envs(Fun, Args, Envs).

now_time() ->
    {{Y, M, D}, {HH, MM, SS}} = calendar:local_time(),
    lists:flatten(io_lib:format("~p.~2..0b.~2..0b.~2..0b.~2..0b.~2..0b", [Y, M, D, HH, MM, SS])).
