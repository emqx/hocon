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

-module(hocon_cli).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-export([atomic_write_files/2, is_valid_now_time/1, restore_backup/2]).
-endif.

-export([main/1]).

-include_lib("kernel/include/file.hrl").

-define(NOW_TIME_LENGTH, 19).
-define(STALE_TMP_AGE_SECONDS, 3600).
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
    ?STDOUT("          check_schema: check a schema but do not generate files", []),
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
        check_schema ->
            check_schema(ParsedArgs);
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

    cleanup_stale_tmp_files(Destination),
    cleanup_stale_tmp_files(DestinationVMArgs),

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

            Files = [
                {DestinationVMArgs, string:join(VmArgs, "\n")},
                {Destination, io_lib:fwrite("~p.\n", [AppConfig])}
            ],
            MaxHistory = proplists:get_value(max_history, ParsedArgs, 3),
            %% Reclaim excess history before staging so an ENOSPC retry can recover.
            prune(Destination, MaxHistory),
            prune(DestinationVMArgs, MaxHistory),
            case atomic_write_files(Files) of
                ok ->
                    %% Enforce the retention limit after both files are in place.
                    prune(Destination, MaxHistory),
                    prune(DestinationVMArgs, MaxHistory);
                {error, Filename, Reason} ->
                    log(error, "Error writing ~s: ~s", [Filename, file:format_error(Reason)]),
                    stop_deactivate()
            end
    catch
        throw:{Schema, Errors} ->
            handle_schema_errors(Schema, Errors)
    end.

-spec check_schema([proplists:property()]) -> ok.
check_schema(ParsedArgs) ->
    Schema = load_schema(ParsedArgs),
    Conf = load_conf(ParsedArgs, fun log/3),
    LogFun = fun(_, _) -> ok end,
    Opts = #{logger => LogFun, apply_override_envs => true},
    try hocon_tconf:generate(Schema, Conf, Opts) of
        _NewConfig ->
            ok
    catch
        throw:{Schema, Errors} ->
            handle_schema_errors(Schema, Errors)
    end.

handle_schema_errors(Schema, Errors) ->
    log(error, "failed_to_check_schema: ~0p", [Schema]),
    lists:foreach(fun(E) -> log(error, "~0p", [E]) end, Errors),
    stop_deactivate().

-spec prune(file:name_all(), non_neg_integer()) -> ok.
prune(Filename, MaxHistory) ->
    %% A Filename comes in /Abs/Path/To/something.YYYY.MM.DD.HH.mm.SS.ext
    %% We want `ls /Abs/Path/To/something.*.ext and delete all but the most
    %% recent MaxHistory
    Path = filename:dirname(Filename),
    Ext = filename:extension(Filename),
    Base = generated_file_base(Filename),
    CurrentFilename = filename:basename(Filename),
    Files =
        lists:sort([
            File
         || File <- directory_files(Path),
            is_generated_filename(File, Base, Ext)
        ]),
    HistoryFiles =
        [filename:join([Path, F]) || F <- Files, F =/= CurrentFilename],
    HistoryLimit = max(MaxHistory - 1, 0),

    delete(HistoryFiles, HistoryLimit),
    ok.

cleanup_stale_tmp_files(Filename) ->
    Path = filename:dirname(Filename),
    Ext = filename:extension(Filename),
    Base = generated_file_base(Filename),
    TmpFiles =
        [
            File
         || File <- directory_files(Path),
            is_generated_tmp_filename(File, Base, Ext)
        ],
    Now = erlang:system_time(second),
    lists:foreach(
        fun(TmpFile) ->
            maybe_cleanup_stale_tmp_file(filename:join(Path, TmpFile), Now)
        end,
        TmpFiles
    ).

generated_file_base(Filename) ->
    Ext = filename:extension(Filename),
    Root = filename:basename(Filename, Ext),
    lists:sublist(Root, length(Root) - ?NOW_TIME_LENGTH - 1).

directory_files(Path) ->
    case file:list_dir(Path) of
        {ok, Files} -> Files;
        {error, _Reason} -> []
    end.

is_generated_filename(Filename, Base, Ext) ->
    Root = filename:basename(Filename, Ext),
    Prefix = Base ++ ".",
    filename:extension(Filename) =:= Ext andalso
        lists:prefix(Prefix, Root) andalso
        is_valid_now_time(lists:nthtail(length(Prefix), Root)).

is_generated_tmp_filename(Filename, Base, Ext) ->
    case filename:extension(Filename) of
        ".tmp" ->
            ReversedParts =
                lists:reverse(string:split(filename:basename(Filename, ".tmp"), ".", all)),
            case ReversedParts of
                [Unique, Pid | ReversedTargetParts] ->
                    is_decimal_string(Pid) andalso
                        is_decimal_string(Unique) andalso
                        is_generated_filename(
                            string:join(lists:reverse(ReversedTargetParts), "."), Base, Ext
                        );
                _Other ->
                    false
            end;
        _Other ->
            false
    end.

is_decimal_string([]) ->
    false;
is_decimal_string(String) ->
    lists:all(fun(Char) -> Char >= $0 andalso Char =< $9 end, String).

maybe_cleanup_stale_tmp_file(TmpFilename, Now) ->
    case file:read_file_info(TmpFilename, [{time, posix}]) of
        {ok, #file_info{type = regular, mtime = MTime}} when
            Now - MTime >= ?STALE_TMP_AGE_SECONDS
        ->
            maybe_log_tmp_cleanup_error(TmpFilename, file:delete(TmpFilename));
        {ok, _FileInfo} ->
            ok;
        {error, enoent} ->
            ok;
        {error, Reason} ->
            log(error, "Could not inspect temporary file ~s, ~0p", [TmpFilename, Reason])
    end.

maybe_log_tmp_cleanup_error(_TmpFilename, ok) ->
    ok;
maybe_log_tmp_cleanup_error(_TmpFilename, {error, enoent}) ->
    ok;
maybe_log_tmp_cleanup_error(TmpFilename, {error, Reason}) ->
    log(error, "Could not delete stale temporary file ~s, ~0p", [TmpFilename, Reason]).

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

-spec atomic_write_files([{file:filename(), iodata()}]) ->
    ok | {error, file:filename(), file_error()}.
atomic_write_files(Files) ->
    atomic_write_files(Files, fun file:rename/2).

-spec atomic_write_files(
    [{file:filename(), iodata()}],
    fun((file:filename(), file:filename()) -> ok | {error, file_error()})
) -> ok | {error, file:filename(), file_error()}.
atomic_write_files(Files, RenameFun) ->
    case stage_files(Files, []) of
        {ok, StagedFiles} ->
            case prepare_staged_files(StagedFiles, []) of
                {ok, PreparedFiles} ->
                    commit_staged_files(PreparedFiles, RenameFun, []);
                {error, Filename, Reason, PreparedFiles} ->
                    cleanup_staged_files(StagedFiles),
                    cleanup_backup_files(PreparedFiles),
                    {error, Filename, Reason}
            end;
        {error, Filename, Reason, StagedFiles} ->
            cleanup_staged_files(StagedFiles),
            {error, Filename, Reason}
    end.

stage_files([], StagedFiles) ->
    {ok, lists:reverse(StagedFiles)};
stage_files([{Filename, Content} | Files], StagedFiles) ->
    case stage_file(Filename, Content) of
        {ok, TmpFilename} ->
            stage_files(Files, [{Filename, TmpFilename} | StagedFiles]);
        {error, Reason} ->
            {error, Filename, Reason, StagedFiles}
    end.

stage_file(Filename, Content) ->
    TmpFilename = temporary_filename(Filename),
    case file:open(TmpFilename, [write, binary, raw, exclusive]) of
        {ok, IoDevice} ->
            case preserve_target_mode(Filename, TmpFilename) of
                ok ->
                    WriteResult = write_and_sync(IoDevice, Content),
                    CloseResult = file:close(IoDevice),
                    case {WriteResult, CloseResult} of
                        {ok, ok} ->
                            {ok, TmpFilename};
                        {{error, Reason}, _} ->
                            _ = file:delete(TmpFilename),
                            {error, Reason};
                        {ok, {error, Reason}} ->
                            _ = file:delete(TmpFilename),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    _ = file:close(IoDevice),
                    _ = file:delete(TmpFilename),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

preserve_target_mode(Filename, TmpFilename) ->
    case file:read_file_info(Filename) of
        {ok, #file_info{type = regular, mode = Mode}} when is_integer(Mode) ->
            file:change_mode(TmpFilename, Mode band 8#777);
        _ ->
            ok
    end.

write_and_sync(IoDevice, Content) ->
    case file:write(IoDevice, Content) of
        ok -> file:sync(IoDevice);
        {error, Reason} -> {error, Reason}
    end.

prepare_staged_files([], PreparedFiles) ->
    {ok, lists:reverse(PreparedFiles)};
prepare_staged_files([{Filename, TmpFilename} | StagedFiles], PreparedFiles) ->
    case backup_file(Filename) of
        {ok, BackupFilename} ->
            PreparedFile = {Filename, TmpFilename, BackupFilename},
            prepare_staged_files(StagedFiles, [PreparedFile | PreparedFiles]);
        {error, Reason} ->
            {error, Filename, Reason, PreparedFiles}
    end.

backup_file(Filename) ->
    case file:read_file(Filename) of
        {ok, Content} -> stage_file(Filename, Content);
        {error, enoent} -> {ok, none};
        {error, Reason} -> {error, Reason}
    end.

commit_staged_files([], _RenameFun, CommittedFiles) ->
    cleanup_backup_files(CommittedFiles),
    ok;
commit_staged_files(
    [{Filename, TmpFilename, _BackupFilename} = PreparedFile | PreparedFiles],
    RenameFun,
    CommittedFiles
) ->
    case RenameFun(TmpFilename, Filename) of
        ok ->
            commit_staged_files(PreparedFiles, RenameFun, [PreparedFile | CommittedFiles]);
        {error, Reason} ->
            cleanup_staged_files([{Filename, TmpFilename} | staged_files(PreparedFiles)]),
            cleanup_backup_files([PreparedFile | PreparedFiles]),
            rollback_committed_files(CommittedFiles),
            {error, Filename, Reason}
    end.

staged_files(PreparedFiles) ->
    [{Filename, TmpFilename} || {Filename, TmpFilename, _BackupFilename} <- PreparedFiles].

rollback_committed_files(CommittedFiles) ->
    lists:foreach(fun rollback_committed_file/1, CommittedFiles).

rollback_committed_file({Filename, _TmpFilename, none}) ->
    maybe_log_rollback_delete_error(Filename, file:delete(Filename));
rollback_committed_file({Filename, _TmpFilename, BackupFilename}) ->
    restore_backup(Filename, BackupFilename).

restore_backup(Filename, BackupFilename) ->
    maybe_log_rollback_error(Filename, file:rename(BackupFilename, Filename)).

maybe_log_rollback_delete_error(_Filename, ok) ->
    ok;
maybe_log_rollback_delete_error(_Filename, {error, enoent}) ->
    ok;
maybe_log_rollback_delete_error(Filename, {error, Reason}) ->
    maybe_log_rollback_error(Filename, {error, Reason}).

maybe_log_rollback_error(_Filename, ok) ->
    ok;
maybe_log_rollback_error(Filename, {error, Reason}) ->
    log(error, "Error rolling back ~s: ~s", [Filename, file:format_error(Reason)]).

cleanup_staged_files(StagedFiles) ->
    lists:foreach(
        fun({_Filename, TmpFilename}) ->
            _ = file:delete(TmpFilename)
        end,
        StagedFiles
    ).

cleanup_backup_files(PreparedFiles) ->
    lists:foreach(
        fun
            ({_Filename, _TmpFilename, none}) -> ok;
            ({_Filename, _TmpFilename, BackupFilename}) -> _ = file:delete(BackupFilename)
        end,
        PreparedFiles
    ).

temporary_filename(Filename) ->
    lists:flatten(
        io_lib:format(
            "~s.~s.~B.tmp",
            [Filename, os:getpid(), erlang:unique_integer([positive, monotonic])]
        )
    ).

filename_maker(Filename, NowTime, Extension) ->
    lists:flatten(io_lib:format("~s.~s.~s", [Filename, NowTime, Extension])).

%% @doc turns a proplist into a list of strings suitable for vm.args files
-spec stringify(undefined | [{any(), string()}]) -> [string()].
stringify(undefined) ->
    [];
stringify(VMArgsProplist) ->
    [stringify_line(K, V) || {K, V} <- VMArgsProplist].

stringify_line('-setcookie', V) ->
    lists:flatten(["-setcookie ", io_lib:format("~0p", [list_to_atom(V)])]);
stringify_line(K, V) when is_list(V) ->
    io_lib:format("~s ~s", [K, V]);
stringify_line(K, V) ->
    io_lib:format("~s ~w", [K, V]).

log_for_generator(_Level, #{hocon_env_var_name := Var, path := P, value := V}) ->
    log_env_override(Var, P, V);
log_for_generator(debug, _Args) ->
    ok;
log_for_generator(info, _Args) ->
    ok;
log_for_generator(Level, Msg) when is_binary(Msg) ->
    io:format(standard_error, "[~0p] ~s~n", [Level, Msg]);
log_for_generator(Level, Args) ->
    io:format(standard_error, "[~0p] ~0p~n", [Level, Args]).

log_env_override(Var, Path, Value) ->
    ValueStr =
        case Value of
            V when is_binary(V) -> V;
            V when is_map(V) -> "{...}";
            [] -> "[]";
            [_ | _] -> "[...]";
            V -> io_lib:format("~0p", [V])
        end,
    ?STDOUT("~s [~s]: ~s", [Var, Path, ValueStr]).

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
