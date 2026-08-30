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

%% This is the work-in-progress unified CLI. The `convert` command from
%% hocon_cli_convert and the old `pp` command have not been migrated yet.
-module(hocon_cli2).

-export([main/1, run/1]).

-define(FORMAT_TEMPLATE, [time, " [", level, "] ", msg, "\n"]).
-define(PROGNAME, "hocon").

-type status() :: 0 | 1 | 2 | 3.

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
        {ok, ArgMap, _Path, #{handler := Handler}} ->
            Handler(unmask_dash_arguments(Marker, ArgMap));
        {error, Reason = {Path, _, _, _}} ->
            stderr("error: ~ts~n", [argparse:format_error(Reason)]),
            stderr("~ts", [argparse:help(Command, ParserOpts#{command => Path})]),
            1
    end.

stdout(CharData) ->
    io:put_chars(standard_io, CharData).

stderr(Format, Args) when is_list(Args) ->
    io:format(standard_error, Format, Args).

mask_dash_arguments(Marker, ["-c", "-" | Rest]) ->
    ["-c", Marker | mask_dash_arguments(Marker, Rest)];
mask_dash_arguments(Marker, ["--conf-file", "-" | Rest]) ->
    ["--conf-file", Marker | mask_dash_arguments(Marker, Rest)];
mask_dash_arguments(Marker, ["--conf-file=-" | Rest]) ->
    ["--conf-file=" ++ Marker | mask_dash_arguments(Marker, Rest)];
mask_dash_arguments(Marker, [Arg | Rest]) ->
    [Arg | mask_dash_arguments(Marker, Rest)];
mask_dash_arguments(_, []) ->
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


cli() ->
    #{
        help => [
            "Read, validate, and generate configuration with HOCON.\n",
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
                        type => {string, ["generate", "get", "validate", "docgen", "help"]},
                        help => "Subcommand"
                    }
                ]
            },
            "generate" => #{
                help => "Generate an Erlang application configuration.",
                handler => fun h_generate/1,
                arguments => schema_arguments() ++ input_arguments() ++ [
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
                arguments => schema_arguments() ++ input_arguments() ++ [
                    #{
                        name => keys,
                        nargs => nonempty_list,
                        help => "Configuration key; multiple keys are accepted"
                    }
                ]
            },
            "validate" => #{
                help => "Check a configuration against a schema without generating output.",
                handler => fun h_validate/1,
                arguments => schema_arguments() ++ input_arguments()
            },
            "docgen" => #{
                help => "Generate Markdown documentation for a schema module.",
                handler => fun h_docgen/1,
                arguments => schema_arguments() ++ [
                    #{
                        name => doctitle,
                        long => "-doctitle",
                        help => "Level-one title for the generated Markdown document"
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

h_help(#{cmd := Command}) ->
    ParserOpts = #{progname => ?PROGNAME, command => [Command]},
    stdout(argparse:help(cli(), ParserOpts)),
    0;
h_help(#{}) ->
    ParserOpts = #{progname => ?PROGNAME},
    stdout(argparse:help(cli(), ParserOpts)),
    0.

h_generate(Args) ->
    setup_logger(Args),
    add_code_paths(Args),
    with_schema_and_conf(Args, fun(Schema, Conf) ->
        case generate_config(Schema, Conf) of
            {ok, Generated} -> write_generated_config(Args, Generated);
            {error, Errors} -> log_schema_errors(Schema, Errors)
        end
    end).

h_get(Args) ->
    setup_logger(Args),
    add_code_paths(Args),
    get_values(Args).

h_validate(Args) ->
    setup_logger(Args),
    add_code_paths(Args),
    with_schema_and_conf(Args, fun(Schema, Conf) ->
        case generate_config(Schema, Conf) of
            {ok, _Generated} -> 0;
            {error, Errors} -> log_schema_errors(Schema, Errors)
        end
    end).

h_docgen(Args) ->
    setup_logger(Args),
    add_code_paths(Args),
    case load_schema(Args) of
        {ok, Schema} ->
            Markdown = hocon_schema_md:gen(Schema, maps:get(doctitle, Args, undefined)),
            io:put_chars(standard_io, Markdown),
            0;
        {error, _Reason} ->
            3
    end.

setup_logger(Args) ->
    LogLevel = maps:get(log_level, Args, notice),
    _ = logger:remove_handler(default),
    _ = logger:remove_handler(hocon_cli2),
    ok = logger:add_handler(
        hocon_cli2,
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
        logger_std_h:filesync(hocon_cli2)
    catch
        _:_ -> ok
    end.

add_code_paths(#{code_paths := Paths}) ->
    lists:foreach(
        fun(Path) -> true = code:add_patha(Path) end,
        Paths
    );
add_code_paths(#{}) ->
    ok.

get_values(#{keys := Keys} = Parsed) ->
    with_schema_and_conf(
        Parsed,
        fun(Schema, Conf) ->
            RootNames = lists:usort([root_name(Schema, Key) || Key <- Keys]),
            try hocon_tconf:map(Schema, Conf, RootNames, tconf_opts()) of
                {_, CheckedConf} ->
                    Values = [{Key, hocon_maps:get(Key, CheckedConf)} || Key <- Keys],
                    print_values(Values),
                    0
            catch
                throw:{Schema, Errors} -> log_schema_errors(Schema, Errors)
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
                    3
            end;
        {error, _Reason} ->
            3
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
                    {ok, Module};
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
            {ok, Module};
        {error, Reason} ->
            logger:error("Could not load compiled schema ~s: ~0p", [SchemaFile, Reason]),
            {error, Reason}
    end.

log_compile_errors(Errors) ->
    lists:foreach(fun(Error) -> logger:error("~0p", [Error]) end, Errors).

log_compile_warnings(Warnings) ->
    lists:foreach(fun(Warning) -> logger:warning("~0p", [Warning]) end, Warnings).

load_conf(Args) ->
    Files = maps:get(conf_files, Args, []),
    IncludeDirs = maps:get(include_dirs, Args, []),
    ParseOpts = #{format => richmap, include_dirs => IncludeDirs},
    logger:debug("ConfFiles: ~0p", [{Files, IncludeDirs}]),
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

generate_config(Schema, Conf) ->
    try hocon_tconf:generate(Schema, Conf, tconf_opts()) of
        Generated -> {ok, Generated}
    catch
        throw:{Schema, Errors} -> {error, Errors}
    end.

tconf_opts() ->
    #{logger => fun log_tconf/2, apply_override_envs => true}.

log_tconf(Level, Msg) when is_binary(Msg) ->
    logger:log(Level, "~ts", [Msg]);
log_tconf(Level, Msg) ->
    logger:log(Level, Msg).

log_schema_errors(Schema, Errors) ->
    logger:error("Failed to check schema ~0p", [Schema]),
    lists:foreach(fun(Error) -> logger:error("~0p", [Error]) end, Errors),
    3.

root_name(Schema, Key) ->
    [RootName | _] = string:lexemes(Key, "."),
    hocon_schema:resolve_struct_name(Schema, RootName).

print_values([{_Key, Value}]) ->
    io:format("~0p~n", [Value]);
print_values(Values) ->
    lists:foreach(fun({Key, Value}) -> io:format("~s=~0p~n", [Key, Value]) end, Values).

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
            2
    end.

write_vm_args(Output, VMArgs) ->
    case write_output(Output, string:join(VMArgs, "\n")) of
        ok ->
            0;
        {error, _Reason} ->
            2
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
