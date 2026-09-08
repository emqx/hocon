%%--------------------------------------------------------------------
%% Copyright (c) 2021-2026 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% Unified HOCON CLI.
-module(hocon_cli).

-export([main/1, run/1]).

-ifdef(TEST).
-export([sync_logger/0]).
-endif.

-define(FORMAT_TEMPLATE, [time, " [", level, "] ", msg, "\n"]).
-define(PROGNAME, "hocon").
-define(STATUS_SUCCESS, 0).
-define(STATUS_USAGE_ERROR, 1).
-define(STATUS_OUTPUT_ERROR, 2).
-define(STATUS_CONFIG_ERROR, 3).

-type status() ::
    ?STATUS_SUCCESS | ?STATUS_USAGE_ERROR | ?STATUS_OUTPUT_ERROR | ?STATUS_CONFIG_ERROR.

main(Args) ->
    Status = run(Args),
    sync_logger(),
    erlang:halt(Status).

-spec run([string()]) -> status().
run(ArgsIn) ->
    Command = cli(),
    Marker = ref_to_list(make_ref()),
    Args = mask_dash_arguments(Marker, ArgsIn),
    ParserOpts = #{progname => ?PROGNAME},
    case argparse:parse(Args, Command, ParserOpts) of
        {ok, ArgMap0, _Path, #{handler := Handler}} ->
            ArgMap = unmask_dash_arguments(Marker, ArgMap0),
            case validate_arguments(ArgMap) of
                ok ->
                    Handler(ArgMap);
                {error, Message} ->
                    stderr("error: ~ts~n", [Message]),
                    ?STATUS_USAGE_ERROR
            end;
        {error, Reason = {Path, _, _, _}} ->
            stderr("error: ~ts~n", [argparse:format_error(Reason)]),
            stderr("~ts", [argparse:help(Command, ParserOpts#{command => tl(Path)})]),
            ?STATUS_USAGE_ERROR
    end.

stdout(CharData) ->
    io:put_chars(standard_io, CharData).

stdout(Format, Args) when is_list(Args) ->
    io:format(standard_io, Format, Args).

stderr(Format, Args) when is_list(Args) ->
    io:format(standard_error, Format, Args).

%% @doc Mask single-dash arguments.
%% `argparse` rejects "-" as an option value because it starts with the option
%% prefix. Mask stdin/stdout markers before parsing and restore them afterwards.
mask_dash_arguments(Marker, Args) ->
    mask_dash_arguments(root, Marker, Args).

mask_dash_arguments(root, Marker, ["format" | Rest]) ->
    ["format" | mask_dash_arguments(format, Marker, Rest)];
mask_dash_arguments(Context, Marker, ["-c", "-" | Rest]) ->
    ["-c", Marker | mask_dash_arguments(Context, Marker, Rest)];
mask_dash_arguments(Context, Marker, ["--conf-file", "-" | Rest]) ->
    ["--conf-file", Marker | mask_dash_arguments(Context, Marker, Rest)];
mask_dash_arguments(Context, Marker, ["--conf-file=-" | Rest]) ->
    ["--conf-file=" ++ Marker | mask_dash_arguments(Context, Marker, Rest)];
mask_dash_arguments(format, Marker, ["-o", "-" | Rest]) ->
    ["-o", Marker | mask_dash_arguments(format, Marker, Rest)];
mask_dash_arguments(format, Marker, ["--output", "-" | Rest]) ->
    ["--output", Marker | mask_dash_arguments(format, Marker, Rest)];
mask_dash_arguments(format, Marker, ["--output=-" | Rest]) ->
    ["--output=" ++ Marker | mask_dash_arguments(format, Marker, Rest)];
mask_dash_arguments(format, Marker, ["-" | Rest]) ->
    [Marker | mask_dash_arguments(format, Marker, Rest)];
mask_dash_arguments(Context, Marker, [Arg | Rest]) ->
    [Arg | mask_dash_arguments(Context, Marker, Rest)];
mask_dash_arguments(_Context, _Marker, []) ->
    [].

unmask_dash_arguments(Marker, ArgMap) ->
    maps:map(
        fun(ArgName, ArgValue) -> unmask_dash_argument(Marker, ArgName, ArgValue) end,
        ArgMap
    ).

unmask_dash_argument(Marker, _, Marker) ->
    dash;
unmask_dash_argument(Marker, ArgName, ValueList = [X | _]) when is_list(X) ->
    [unmask_dash_argument(Marker, ArgName, V) || V <- ValueList];
unmask_dash_argument(_, _, ArgValue) ->
    ArgValue.

validate_arguments(#{conf_files := Files}) ->
    case lists:member(dash, Files) andalso Files =/= [dash] of
        true -> {error, "'-' must be the only input file"};
        false -> ok
    end;
validate_arguments(_Args) ->
    ok.

cli() ->
    #{
        help => [
            "Read, format, validate, and generate configuration with HOCON.\n",
            commands,
            arguments,
            options
        ],
        handler => fun h_help/1,
        arguments => global_arguments(),
        commands => #{
            "help" => #{
                help => "Print subcommand help.",
                handler => fun h_help/1,
                arguments => [
                    #{
                        name => cmd,
                        required => false,
                        nargs => 'maybe',
                        type =>
                            {string, ["generate", "get", "validate", "docgen", "format", "help"]},
                        help => "Subcommand"
                    }
                ]
            },
            "generate" => #{
                help => "Generate an Erlang application configuration.",
                handler => fun h_generate/1,
                arguments => schema_arguments() ++ input_arguments() ++ logenv_arguments() ++
                    [
                        #{
                            name => config_output,
                            required => true,
                            long => "-out-app-config",
                            help => "Application configuration output"
                        },
                        #{
                            name => vm_args_output,
                            required => true,
                            long => "-out-vm-args",
                            help => "VM arguments output"
                        }
                    ]
            },
            "get" => #{
                help => "Get one or more values from a checked configuration.",
                handler => fun h_get/1,
                arguments => schema_arguments() ++ input_arguments() ++
                    [
                        #{
                            name => keys,
                            nargs => nonempty_list,
                            help =>
                                "Configuration key; multiple keys are accepted.\n"
                                "Complex values are formatted as single-line HOCON documents."
                        }
                    ]
            },
            "validate" => #{
                help => "Check a configuration against a schema without generating output.",
                handler => fun h_validate/1,
                arguments => schema_arguments() ++ input_arguments() ++ logenv_arguments()
            },
            "docgen" => #{
                help => "Generate Markdown documentation for a schema module.",
                handler => fun h_docgen/1,
                arguments => schema_arguments() ++
                    [
                        #{
                            name => doctitle,
                            long => "-doctitle",
                            help => "Level-one title for the generated Markdown document"
                        }
                    ]
            },
            "format" => #{
                help => "Format HOCON as HOCON, JSON, or YAML.",
                handler => fun h_format/1,
                arguments => [
                    #{
                        name => output_format,
                        short => $F,
                        long => "-format",
                        type => {atom, [hocon, json, yaml]},
                        default => hocon,
                        help => "Output format"
                    },
                    #{
                        name => output,
                        short => $o,
                        long => "-output",
                        help => "Output file; '-' or omission means stdout"
                    },
                    #{
                        name => include_dirs,
                        short => $I,
                        long => "-include-dir",
                        action => append,
                        help => "Directory used to resolve includes; may be repeated"
                    },
                    #{
                        name => conf_files,
                        nargs => list,
                        required => false,
                        help =>
                            "HOCON input file; multiple files are accepted. "
                            "Use '-' or omit to read stdin"
                    }
                ]
            }
        }
    }.

global_arguments() ->
    [
        #{
            name => log_level,
            short => $l,
            long => "-log-level",
            type => {atom, [debug, info, notice, warning, error, critical, alert, emergency]},
            default => notice,
            help => "Minimum log level"
        }
    ].

schema_arguments() ->
    [
        #{
            name => schema_module,
            short => $s,
            long => "-schema-module",
            help => "Schema module name"
        },
        #{
            name => schema_file,
            short => $i,
            long => "-schema-file",
            help => "Erlang source file containing the schema module"
        },
        #{
            name => code_paths,
            long => "-pa",
            action => append,
            help => "Prepend a code path; may be repeated"
        }
    ].

input_arguments() ->
    [
        #{
            name => conf_files,
            short => $c,
            long => "-conf-file",
            action => append,
            help => "HOCON input file; may be repeated. Use '-' or omit to read stdin"
        },
        #{
            name => include_dirs,
            short => $I,
            long => "-include-dir",
            action => append,
            help => "Directory used to resolve includes; may be repeated"
        }
    ].

logenv_arguments() ->
    [
        #{
            name => log_env_overrides,
            short => $v,
            long => "-log-env-overrides",
            action => {store, true},
            default => false,
            help => "Print applied environment overrides to stdout"
        }
    ].

h_help(#{cmd := Command}) ->
    ParserOpts = #{progname => ?PROGNAME, command => [Command]},
    stdout(argparse:help(cli(), ParserOpts)),
    ?STATUS_SUCCESS;
h_help(#{}) ->
    ParserOpts = #{progname => ?PROGNAME},
    stdout(argparse:help(cli(), ParserOpts)),
    ?STATUS_SUCCESS.

h_generate(Args) ->
    setup_logger(Args),
    with_code_paths(Args, fun() ->
        with_schema_and_conf(Args, fun(Schema, Conf) ->
            case generate_config(Schema, Conf, tconf_opts(Args)) of
                {ok, Generated} -> write_generated_config(Args, Generated);
                {error, Errors} -> log_schema_errors(Schema, Errors)
            end
        end)
    end).

h_get(Args) ->
    setup_logger(Args),
    with_code_paths(Args, fun() -> get_values(Args) end).

h_validate(Args) ->
    setup_logger(Args),
    with_code_paths(Args, fun() ->
        with_schema_and_conf(Args, fun(Schema, Conf) ->
            case generate_config(Schema, Conf, tconf_opts(Args)) of
                {ok, _Generated} ->
                    ?STATUS_SUCCESS;
                {error, Errors} ->
                    log_schema_errors(Schema, Errors)
            end
        end)
    end).

h_docgen(Args) ->
    setup_logger(Args),
    with_code_paths(Args, fun() ->
        case load_schema(Args) of
            {ok, Schema} ->
                Markdown = hocon_schema_md:gen(Schema, maps:get(doctitle, Args, undefined)),
                stdout(Markdown),
                ?STATUS_SUCCESS;
            {error, _Reason} ->
                ?STATUS_CONFIG_ERROR
        end
    end).

h_format(Args) ->
    setup_logger(Args),
    case load_conf(map, Args) of
        {ok, Conf} ->
            Content = format_conf(maps:get(output_format, Args), Conf),
            case write_output(maps:get(output, Args, dash), Content) of
                ok ->
                    ?STATUS_SUCCESS;
                {error, _Reason} ->
                    ?STATUS_OUTPUT_ERROR
            end;
        {error, _Reason} ->
            ?STATUS_CONFIG_ERROR
    end.

setup_logger(Args) ->
    LogLevel = maps:get(log_level, Args, notice),
    _ = logger:remove_handler(default),
    _ = logger:remove_handler(hocon_cli),
    ok = logger:add_handler(
        hocon_cli,
        logger_std_h,
        #{
            config => #{type => standard_error},
            formatter =>
                {logger_formatter, #{
                    legacy_header => false,
                    single_line => true,
                    template => ?FORMAT_TEMPLATE
                }},
            filter_default => log,
            filters => [],
            level => all
        }
    ),
    logger:set_primary_config(level, LogLevel).

sync_logger() ->
    try
        logger_std_h:filesync(hocon_cli)
    catch
        _:_ -> ok
    end.

add_code_paths(#{code_paths := Paths}) ->
    add_code_paths(Paths);
add_code_paths(#{}) ->
    ok;
add_code_paths([Path | Rest]) ->
    case code:add_patha(Path) of
        true ->
            add_code_paths(Rest);
        {error, bad_directory} = Error ->
            logger:error("Could not add code path ~ts: not an existing directory", [Path]),
            Error
    end;
add_code_paths([]) ->
    ok.

with_code_paths(Args, Fun) ->
    case add_code_paths(Args) of
        ok ->
            Fun();
        {error, _Reason} ->
            ?STATUS_CONFIG_ERROR
    end.

get_values(#{keys := Keys} = Parsed) ->
    with_schema_and_conf(
        Parsed,
        fun(Schema, Conf) ->
            try
                RootNames = lists:usort([root_name(Schema, Key) || Key <- Keys]),
                {_, CheckedConf} = hocon_tconf:map(Schema, Conf, RootNames, tconf_opts_get()),
                Values = [{Key, hocon_maps:get_source(Key, CheckedConf)} || Key <- Keys],
                print_values(Values),
                ?STATUS_SUCCESS
            catch
                throw:{invalid_key, Key} ->
                    logger:error("Key ~0p is invalid", [Key]),
                    ?STATUS_USAGE_ERROR;
                throw:{unknown_struct_name, Schema, StructName} ->
                    logger:error("Unknown ~0p root: ~s", [Schema, StructName]),
                    ?STATUS_CONFIG_ERROR;
                throw:{Schema, Errors} ->
                    log_schema_errors(Schema, Errors)
            end
        end
    ).

with_schema_and_conf(Parsed, Fun) ->
    case load_schema(Parsed) of
        {ok, Schema} ->
            case load_conf(Parsed) of
                {ok, Conf} ->
                    Fun(Schema, Conf);
                {error, _Reason} ->
                    ?STATUS_CONFIG_ERROR
            end;
        {error, _Reason} ->
            ?STATUS_CONFIG_ERROR
    end.

load_schema(Args) ->
    case {maps:get(schema_file, Args, undefined), maps:get(schema_module, Args, undefined)} of
        {undefined, undefined} ->
            logger:error("A schema module or schema file is required"),
            {error, missing_schema};
        {SchemaFile, _SchemaModule} when SchemaFile =/= undefined ->
            compile_schema(SchemaFile);
        {undefined, SchemaModule} ->
            Module = list_to_atom(SchemaModule),
            case code:ensure_loaded(Module) of
                {module, Module} ->
                    validate_schema_module(Module);
                {error, Reason} ->
                    logger:error("Could not load schema module ~s: ~0p", [SchemaModule, Reason]),
                    {error, Reason}
            end
    end.

compile_schema(SchemaFile) ->
    ErlLibs = os:getenv("ERL_LIBS", ""),
    CompileOpts = [binary, return_errors, return_warnings, {i, ErlLibs}],
    case compile:file(SchemaFile, CompileOpts) of
        {ok, Module, Beam} ->
            load_compiled_schema(Module, SchemaFile, Beam);
        {ok, Module, Beam, Warnings} ->
            log_compile_warnings(Warnings),
            load_compiled_schema(Module, SchemaFile, Beam);
        {error, Errors, Warnings} ->
            log_compile_errors(Errors),
            log_compile_warnings(Warnings),
            {error, compile_schema}
    end.

load_compiled_schema(Module, SchemaFile, Beam) ->
    case code:load_binary(Module, SchemaFile, Beam) of
        {module, Module} ->
            validate_schema_module(Module);
        {error, Reason} ->
            logger:error("Could not load compiled schema ~s: ~0p", [SchemaFile, Reason]),
            {error, Reason}
    end.

validate_schema_module(Module) ->
    case hocon_schema:is_schema(Module) of
        true ->
            {ok, Module};
        false ->
            logger:error("Module ~p is not a HOCON schema", [Module]),
            {error, invalid_schema_module};
        {error, Reason} ->
            logger:error("Module ~p is not loaded: ~0p", [Module, Reason]),
            {error, Reason}
    end.

log_compile_errors(Errors) ->
    log_compile_diagnostics(error, Errors).

log_compile_warnings(Warnings) ->
    log_compile_diagnostics(warning, Warnings).

log_compile_diagnostics(Level, Diagnostics) ->
    lists:foreach(
        fun({Filename, FileDiagnostics}) ->
            lists:foreach(
                fun({Location, Module, Description}) ->
                    Diagnostic = {Location, Module, Description},
                    logger:log(Level, "~ts", [format_compile_diagnostic(Filename, Diagnostic)])
                end,
                FileDiagnostics
            )
        end,
        Diagnostics
    ).

format_compile_diagnostic(Filename, {Location, Module, Description}) ->
    FormattedError = apply(Module, format_error, [Description]),
    [format_source_location(Filename, Location), ": ", FormattedError].

format_source_location(Filename, {Line, Column}) ->
    io_lib:format("~ts:~B:~B", [Filename, Line, Column]);
format_source_location(Filename, Line) when is_integer(Line) ->
    io_lib:format("~ts:~B", [Filename, Line]);
format_source_location(Filename, none) ->
    Filename.

load_conf(Args) ->
    load_conf(richmap, Args).

load_conf(MapFormat, Args) when MapFormat =:= map; MapFormat =:= richmap ->
    Files = maps:get(conf_files, Args, []),
    IncludeDirs = maps:get(include_dirs, Args, []),
    ParseOpts = #{format => MapFormat, include_dirs => IncludeDirs},
    logger:debug("ConfFiles: ~0p", [{Files, IncludeDirs}]),
    parse_conf(Files, ParseOpts).

parse_conf(Files, ParseOpts) ->
    Result =
        case Files of
            [] ->
                hocon:binary(slurp_standard_input(), ParseOpts);
            [dash] ->
                hocon:binary(slurp_standard_input(), ParseOpts);
            _ ->
                hocon:files(Files, ParseOpts)
        end,
    case Result of
        {ok, Conf} ->
            {ok, Conf};
        {error, Reason} ->
            logger:error("Could not parse HOCON input: ~0p", [Reason]),
            {error, Reason}
    end.

slurp_standard_input() ->
    slurp_standard_input([]).

slurp_standard_input(Acc) ->
    case io:get_chars(standard_io, "", 32768) of
        eof ->
            lists:reverse(Acc);
        Data when is_binary(Data); is_list(Data) ->
            slurp_standard_input([Data | Acc])
    end.

generate_config(Schema, Conf, Opts) ->
    try hocon_tconf:generate(Schema, Conf, Opts) of
        Generated ->
            {ok, Generated}
    catch
        throw:{Schema, Errors} ->
            {error, Errors}
    end.

tconf_opts(Opts) ->
    #{
        logger => fun(Level, Msg) -> log_tconf(Level, Msg, Opts) end,
        apply_override_envs => true
    }.

tconf_opts_get() ->
    #{
        logger => fun(_, _) -> ok end,
        apply_override_envs => true,
        format => {richmap, #{keep_source => true}}
    }.

log_tconf(
    _Level,
    #{hocon_env_var_name := Var, path := Path, value := Value},
    #{log_env_overrides := true}
) ->
    log_env_override(Var, Path, Value);
log_tconf(_Level, #{hocon_env_var_name := _}, _Opts) ->
    ok;
log_tconf(Level, Msg, _Opts) when is_binary(Msg) ->
    logger:log(Level, "~ts", [Msg]);
log_tconf(Level, Msg, _Opts) ->
    logger:log(Level, Msg).

log_env_override(Var, Path, Value) ->
    %% NOTE: Adapted from legacy CLI.
    {FmtArg, FmtValue} =
        case Value of
            V when is_binary(V) -> {"~s", V};
            #{} -> {"~s", <<"{...}">>};
            [] -> {"~s", <<"[]">>};
            [_ | _] -> {"~s", <<"[...]">>};
            V -> {"~0tp", V}
        end,
    stdout("~ts [~ts]: " ++ FmtArg ++ "~n", [Var, Path, FmtValue]).

log_schema_errors(Schema, Errors) ->
    logger:error("Failed to check schema ~0p", [Schema]),
    lists:foreach(fun(Error) -> logger:error("~0p", [Error]) end, Errors),
    ?STATUS_CONFIG_ERROR.

root_name(Schema, Key) ->
    case string:lexemes(Key, ".") of
        [RootName | _] ->
            hocon_schema:resolve_struct_name(Schema, RootName);
        [] ->
            throw({invalid_key, Key})
    end.

print_values([{_Key, Value}]) ->
    io:format("~s~n", [print_value(Value)]);
print_values(Values) ->
    lists:foreach(
        fun({Key, Value}) ->
            io:format("~s=~s~n", [Key, print_value(Value)])
        end,
        Values
    ).

print_value(V) ->
    hocon_pp:do(V, #{embedded => true, newline => ""}).

write_generated_config(Args, Generated) ->
    AppConfig = proplists:delete(vm_args, Generated),
    AppOutput = maps:get(config_output, Args),
    VMArgsOutput = maps:get(vm_args_output, Args),
    AppContent = io_lib:fwrite("~p.~n", [AppConfig]),
    VMArgs = stringify(proplists:get_value(vm_args, Generated)),
    case write_output(AppOutput, AppContent) of
        ok ->
            write_vm_args(VMArgsOutput, VMArgs);
        {error, _Reason} ->
            ?STATUS_OUTPUT_ERROR
    end.

write_vm_args(Output, VMArgs) ->
    case write_output(Output, string:join(VMArgs, "\n")) of
        ok ->
            ?STATUS_SUCCESS;
        {error, _Reason} ->
            ?STATUS_OUTPUT_ERROR
    end.

write_output(dash, Content) ->
    stdout(Content);
write_output(Filename, Content) ->
    case file:write_file(Filename, Content) of
        ok ->
            ok;
        {error, Reason} ->
            logger:error("Could not write ~s: ~s", [Filename, file:format_error(Reason)]),
            {error, Reason}
    end.

stringify(undefined) ->
    [];
stringify(VMArgsProplist) ->
    [stringify_line(Key, Value) || {Key, Value} <- VMArgsProplist].

stringify_line('-setcookie', Value) ->
    lists:flatten(["-setcookie ", io_lib:format("~0p", [list_to_atom(Value)])]);
stringify_line(Key, Value) when is_list(Value) ->
    lists:flatten(io_lib:format("~s ~s", [Key, Value]));
stringify_line(Key, Value) ->
    lists:flatten(io_lib:format("~s ~w", [Key, Value])).

%%--------------------------------------------------------------------
%% Configuration formatter
%%--------------------------------------------------------------------

format_conf(hocon, Conf) ->
    hocon_pp:do(Conf, #{});
format_conf(json, Conf) ->
    json:format(Conf);
format_conf(yaml, Conf) ->
    format_yaml(Conf).

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
