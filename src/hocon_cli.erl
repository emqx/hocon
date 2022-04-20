%%--------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon_cli).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([is_valid_now_time/1]).
-endif.

-export([main/1]).

-define(STDERR(Str, Args), io:format(standard_error, Str ++ "~n", Args)).
-define(STDOUT(Str, Args), io:format(Str ++ "~n", Args)).
-define(FORMAT_TEMPLATE, [time, " [", level, "] ", msg, "\n"]).

%% copied from file:format_error/1
-type file_error() ::
    file:posix()
    | badarg
    | terminated
    | system_limit
    | {integer(), module(), term()}.

-elvis([{elvis_style, macro_module_names, disable}]).

cli_options() ->
    %% Option Name, Short Code, Long Code, Argument Spec, Help Message
    [
        {help, $h, "help", undefined, "Print this usage page"},
        {dest_dir, $d, "dest_dir", string, "specifies the directory to write the config file to"},
        {include_dirs, $I, "include_dir", string, "specifies the directory to search include file"},
        {dest_file, $f, "dest_file", {string, "app"}, "the file name to write"},
        {schema_file, $i, "schema_file", string, "the file name of schema module"},
        {schema_module, $s, "schema_module", atom, "the name of schema module"},
        {conf_file, $c, "conf_file", string, "hocon conf file, multiple files allowed"},
        {log_level, $l, "log_level", {string, "notice"}, "log level"},
        {max_history, $m, "max_history", {integer, 3},
            "the maximum number of generated config files to keep"},
        {now_time, $t, "now_time", string, "the time suffix for generated files"},
        {verbose_env, $v, "verbose_env", {boolean, false},
            "whether to log env overrides to stdout"},
        {pa, undefined, "pa", string,
            "like the -pa flag for erl command, prepend path to load beam files, "
            "comma separate multiple paths"},
        {doctitle, undefined, "doctitle", string,
            "this option is only valid for docgen command, "
            "the string will be used as the head-1 title "
            "of the generated markdown document"}
    ].

print_help() ->
    ?STDOUT("Commands: now_time: get the current time for generate command's -t option", []),
    ?STDOUT("          generate: generate app.<time>.config and vm.<time>.args", []),
    ?STDOUT("          get: get value of a given key", []),
    ?STDOUT("          multi_get: get values for given list of keys", []),
    ?STDOUT("          docgen: generate doc for a given schema module", []),
    ?STDOUT("", []),
    getopt:usage(cli_options(), "hocon generate"),
    stop_deactivate().

parse_and_command(Args) ->
    {ParsedArgs, Extra} =
        case getopt:parse(cli_options(), Args) of
            {ok, {P, H}} -> {P, H};
            _ -> {[help], []}
        end,
    {Command, ExtraArgs} =
        case {lists:member(help, ParsedArgs), Extra} of
            {false, []} -> {generate, []};
            {false, [Cmd | E]} -> {list_to_atom(Cmd), E};
            _ -> {help, []}
        end,
    {Command, ParsedArgs, ExtraArgs}.

%% @doc Entry point of the script
main(Args) ->
    {Command, ParsedArgs, Extra} = parse_and_command(Args),

    SuggestedLogLevel = list_to_atom(proplists:get_value(log_level, ParsedArgs)),
    LogLevel =
        case
            lists:member(SuggestedLogLevel, [
                debug,
                info,
                notice,
                warning,
                error,
                critical,
                alert,
                emergency
            ])
        of
            true -> SuggestedLogLevel;
            _ -> notice
        end,
    logger:remove_handler(default),
    logger:add_handler(
        hocon_cli,
        logger_std_h,
        #{
            config => #{type => standard_io},
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

    logger:set_primary_config(level, LogLevel),
    case Command of
        help ->
            print_help();
        get ->
            get(ParsedArgs, Extra);
        multi_get ->
            multi_get(ParsedArgs, Extra);
        generate ->
            generate(ParsedArgs);
        now_time ->
            now_time();
        docgen ->
            docgen(ParsedArgs);
        pp ->
            pretty_print(ParsedArgs);
        _Other ->
            print_help()
    end.

%% equav command: date -u +"%Y.%m.%d.%H.%M.%S"
now_time() ->
    {{Y, M, D}, {HH, MM, SS}} = calendar:local_time(),
    Res = io_lib:format("~0p.~2..0b.~2..0b.~2..0b.~2..0b.~2..0b", [Y, M, D, HH, MM, SS]),
    ?STDOUT("~s", [Res]),
    lists:flatten(Res).

is_valid_now_time(T) ->
    re:run(T, "^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}$") =/= nomatch.

-spec get([proplists:property()], [string()]) -> no_return().
get(_ParsedArgs, []) ->
    %% No query, you get nothing.
    ?STDOUT("HOCON 'get' command requires one config key to query.", []),
    stop_deactivate();
get(ParsedArgs, [Key | _]) ->
    Schema = load_schema(ParsedArgs),
    Conf = load_conf(ParsedArgs, fun log_for_get/3),
    [{_, Value}] = get_values(Schema, Conf, [Key]),
    ?STDOUT("~0p", [Value]),
    stop_ok().

multi_get(_ParsedArgs, []) ->
    ?STDOUT("HOCON 'multi_get' command requires one or more configs keys to query.", []),
    ?STDOUT("Try `get setting.name1 setting.name2`", []),
    ?STDOUT("The output format is name=value one line for each value.", []),
    ?STDOUT("It does not work well for string values having line breaks ", []),
    stop_deactivate();
multi_get(ParsedArgs, Keys) ->
    Schema = load_schema(ParsedArgs),
    Conf = load_conf(ParsedArgs, fun log_for_get/3),
    Values = get_values(Schema, Conf, Keys),
    lists:foreach(fun({K, V}) -> ?STDOUT("~s=~0p", [K, V]) end, Values),
    stop_ok().

get_values(_Schema, _Conf, []) ->
    [];
get_values(Schema, Conf, [Key | Rest]) ->
    %% map only the desired root name
    [RootName0 | _] = string:tokens(Key, "."),
    RootName = hocon_schema:resolve_struct_name(Schema, RootName0),
    %% do not log anything for `get` commands
    Opts = #{logger => fun(_, _) -> ok end, apply_override_envs => true},
    {_, NewConf} = hocon_tconf:map(Schema, Conf, [RootName], Opts),
    [{Key, hocon_maps:get(Key, NewConf)} | get_values(Schema, Conf, Rest)].

pretty_print(ParsedArgs) ->
    Conf0 = load_conf(ParsedArgs, fun log/3),
    Conf = hocon_util:richmap_to_map(Conf0),
    ?STDOUT("~ts", [hocon_pp:do(Conf, #{})]).

docgen(ParsedArgs) ->
    case load_schema(ParsedArgs) of
        undefined ->
            ?STDOUT("hocon's docgen command requires a schema module, use -s option", []),
            stop_deactivate();
        Module ->
            Title = proplists:get_value(doctitle, ParsedArgs),
            io:format(user, "~s", [hocon_schema_md:gen(Module, Title)])
    end.

load_schema(ParsedArgs) ->
    case proplists:get_value(pa, ParsedArgs) of
        undefined ->
            ok;
        DirsStr ->
            Dirs = string:tokens(DirsStr, ","),
            lists:foreach(fun(Dir) -> code:add_patha(Dir) end, Dirs)
    end,
    case
        {
            proplists:get_value(schema_file, ParsedArgs),
            proplists:get_value(schema_module, ParsedArgs)
        }
    of
        {undefined, Mod0} ->
            Mod0;
        {SchemaFile, _} ->
            ErlLibs = os:getenv("ERL_LIBS", ""),
            {ok, Module} = compile:file(SchemaFile, [{i, ErlLibs}]),
            Module
    end.

-spec load_conf([proplists:property()], function()) -> hocon:config() | no_return().
load_conf(ParsedArgs, LogFunc) ->
    ConfFiles = proplists:get_all_values(conf_file, ParsedArgs),
    IncDirs = proplists:get_all_values(include_dirs, ParsedArgs),
    LogFunc(debug, "ConfFiles: ~0p", [{ConfFiles, IncDirs}]),
    case hocon:files(ConfFiles, #{format => richmap, include_dirs => IncDirs}) of
        {error, E} ->
            LogFunc(error, "~0p~n", [E]),
            stop_deactivate();
        {ok, Conf} ->
            Conf
    end.

-spec writable_destination_path([proplists:property()]) -> file:filename() | error.
writable_destination_path(ParsedArgs) ->
    DestinationPath = proplists:get_value(dest_dir, ParsedArgs),
    case DestinationPath =:= undefined of
        true ->
            log(error, "Missing -d|--dest_dir option", []),
            stop_deactivate();
        _ ->
            ok
    end,
    AbsoluteDestPath = filename:absname(DestinationPath),
    %% Check Permissions
    case filelib:ensure_dir(filename:join(AbsoluteDestPath, "weaksauce.dummy")) of
        %% filelib:ensure_dir/1 requires a dummy filename in the argument,
        %% I think that is weaksauce, hence "weaksauce.dummy"
        ok ->
            AbsoluteDestPath;
        {error, E} ->
            log(
                error,
                "Error creating ~s: ~s",
                [AbsoluteDestPath, file:format_error(E)]
            ),
            error
    end.

-spec generate([proplists:property()]) -> ok.
generate(ParsedArgs) ->
    AbsPath =
        case writable_destination_path(ParsedArgs) of
            error -> stop_deactivate();
            Path -> Path
        end,

    DestFile = proplists:get_value(dest_file, ParsedArgs),

    NowTime0 = proplists:get_value(now_time, ParsedArgs),
    NowTime =
        case NowTime0 =:= undefined of
            true -> now_time();
            false -> NowTime0
        end,
    case is_valid_now_time(NowTime) of
        true ->
            ok;
        false ->
            log(
                error,
                "bad -t|--now_time option, get it from this script's now_time command or "
                "from command: date +'%Y.%m.%d.%H.%M.%S'",
                []
            ),
            stop_deactivate()
    end,

    DestinationFilename = filename_maker(DestFile, NowTime, "config"),
    Destination = filename:join(AbsPath, DestinationFilename),

    DestinationVMArgsFilename = filename_maker("vm", NowTime, "args"),
    DestinationVMArgs = filename:join(AbsPath, DestinationVMArgsFilename),
    log(debug, "Generating config in: ~0p", [Destination]),

    Schema = load_schema(ParsedArgs),
    Conf = load_conf(ParsedArgs, fun log/3),
    LogFun =
        case proplists:get_value(verbose_env, ParsedArgs) of
            true -> fun log_for_generator/2;
            false -> fun(_, _) -> ok end
        end,
    Opts = #{logger => LogFun, apply_override_envs => true},
    try hocon_tconf:generate(Schema, Conf, Opts) of
        NewConfig ->
            AppConfig = proplists:delete(vm_args, NewConfig),
            VmArgs = stringify(proplists:get_value(vm_args, NewConfig)),

            %% Prune excess files
            MaxHistory = proplists:get_value(max_history, ParsedArgs, 3) - 1,
            prune(Destination, MaxHistory),
            prune(DestinationVMArgs, MaxHistory),

            case
                {
                    file:write_file(Destination, io_lib:fwrite("~p.\n", [AppConfig])),
                    file:write_file(DestinationVMArgs, string:join(VmArgs, "\n"))
                }
            of
                {ok, ok} ->
                    ok;
                {Err1, Err2} ->
                    maybe_log_file_error(Destination, Err1),
                    maybe_log_file_error(DestinationVMArgs, Err2),
                    stop_deactivate()
            end
    catch
        throw:{Schema, Errors} ->
            log(error, "failed_to_check_schema: ~0p", [Schema]),
            lists:foreach(fun(E) -> log(error, "~0p", [E]) end, Errors),
            stop_deactivate()
    end.

-spec prune(file:name_all(), non_neg_integer()) -> ok.
prune(Filename, MaxHistory) ->
    %% A Filename comes in /Abs/Path/To/something.YYYY.MM.DD.HH.mm.SS.ext
    %% We want `ls /Abs/Path/To/something.*.ext and delete all but the most
    %% recent MaxHistory
    Path = filename:dirname(Filename),
    Ext = filename:extension(Filename),
    Base = hd(string:tokens(filename:basename(Filename, Ext), ".")),
    Files =
        lists:sort(filelib:wildcard(Base ++ ".*" ++ Ext, Path)),

    delete([filename:join([Path, F]) || F <- Files], MaxHistory),
    ok.

-spec delete(file:name_all(), non_neg_integer()) -> ok.
delete(Files, MaxHistory) when length(Files) =< MaxHistory ->
    ok;
delete(Files, MaxHistory) ->
    do_delete(Files, length(Files) - MaxHistory).

do_delete(_Files, 0) ->
    ok;
do_delete([File | Files], Left) ->
    case file:delete(File) of
        ok -> ok;
        {error, Reason} -> log(error, "Could not delete ~s, ~0p", [File, Reason])
    end,
    do_delete(Files, Left - 1).

-spec maybe_log_file_error(file:filename(), ok | {error, file_error()}) -> ok.
maybe_log_file_error(_, ok) ->
    ok;
maybe_log_file_error(Filename, {error, Reason}) ->
    log(error, "Error writing ~s: ~s", [Filename, file:format_error(Reason)]),
    ok.

filename_maker(Filename, NowTime, Extension) ->
    lists:flatten(io_lib:format("~s.~s.~s", [Filename, NowTime, Extension])).

%% @doc turns a proplist into a list of strings suitable for vm.args files
-spec stringify(undefined | [{any(), string()}]) -> [string()].
stringify(undefined) ->
    [];
stringify(VMArgsProplist) ->
    [stringify_line(K, V) || {K, V} <- VMArgsProplist].

stringify_line(K, V) when is_list(V) ->
    io_lib:format("~s ~s", [K, V]);
stringify_line(K, V) ->
    io_lib:format("~s ~w", [K, V]).

log_for_generator(_Level, #{hocon_env_var_name := Var, path := P, value := V}) when is_binary(V) ->
    ?STDOUT("~s = ~s = ~s", [P, Var, V]);
log_for_generator(_Level, #{hocon_env_var_name := Var, path := P, value := V}) ->
    ?STDOUT("~s = ~s = ~0p", [P, Var, V]);
log_for_generator(debug, _Args) ->
    ok;
log_for_generator(info, _Args) ->
    ok;
log_for_generator(Level, Msg) when is_binary(Msg) ->
    io:format(standard_error, "[~0p] ~s~n", [Level, Msg]);
log_for_generator(Level, Args) ->
    io:format(standard_error, "[~0p] ~0p~n", [Level, Args]).

-ifndef(TEST).
stop_deactivate() ->
    init:stop(1),
    %% wait for logger to print all errors
    timer:sleep(100),
    stop_deactivate().

stop_ok() ->
    init:stop(0).
-endif.

-ifdef(TEST).
%% In test mode we don't want to kill the test VM prematurely.
stop_deactivate() ->
    throw(stop_deactivate).

stop_ok() ->
    ok.
-endif.

log(Level, Fmt, Args) ->
    logger:Level(Fmt, Args).

%% log to stderr for 'get' command
log_for_get(L, Fmt, Args) when L =:= debug orelse L =:= info ->
    case os:getenv("DEBUG") of
        "1" -> ?STDERR("[~0p]: " ++ Fmt, [L | Args]);
        _ -> ok
    end;
log_for_get(L, Fmt, Args) ->
    ?STDERR("[~0p]: " ++ Fmt, [L | Args]).
