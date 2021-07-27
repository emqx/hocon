%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-define(FORMAT(Str, Args), io_lib:format(Str, Args)).
-define(FORMAT_TEMPLATE, [time, " [", level, "] ", msg, "\n"]).

-type file_error() :: file:posix()  %% copied from file:format_error/1
                    | badarg
                    | terminated
                    | system_limit
                    | {integer(), module(), term()}.

-elvis([{elvis_style, macro_module_names, disable}]).

cli_options() ->
%% Option Name, Short Code, Long Code, Argument Spec, Help Message
    [
      {help, $h, "help", undefined, "Print this usage page"}
    , {etc_dir, $e, "etc_dir", {string, "/etc"}, "etc dir"}
    , {dest_dir, $d, "dest_dir", string, "specifies the directory to write the config file to"}
    , {dest_file, $f, "dest_file", {string, "app"}, "the file name to write"}
    , {schema_file, $i, "schema_file", string, "the file name of schema module"}
    , {schema_module, $s, "schema_module", atom, "the name of schema module"}
    , {conf_file, $c, "conf_file", string, "hocon conf file, multiple files allowed"}
    , {log_level, $l, "log_level", {string, "notice"}, "log level"}
    , {max_history, $m, "max_history", {integer, 3},
        "the maximum number of generated config files to keep"}
    , {now_time, $t, "now_time", string, "the time suffix for generated files"}
    , {verbose_env, $v, "verbose_env", {boolean, false}, "whether to log env overrides to stdout"}
    ].

print_help() ->
    ?STDOUT("Commands: now_time: get the current time for generate command's -t option", []),
    ?STDOUT("          generate: generate app.<time>.config and vm.<time>.args", []),
    ?STDOUT("          get: get value of a given key", []),
    ?STDOUT("", []),
    getopt:usage(cli_options(), "hocon generate"),
    stop_deactivate().

parse_and_command(Args) ->
    {ParsedArgs, Extra} = case getopt:parse(cli_options(), Args) of
                              {ok, {P, H}} -> {P, H};
                              _ -> {[help], []}
                          end,
    {Command, ExtraArgs} = case {lists:member(help, ParsedArgs), Extra} of
                               {false, []} -> {generate, []};
                               {false, [Cmd | E]} -> {list_to_atom(Cmd), E};
                               _ -> {help, []}
                           end,
    {Command, ParsedArgs, ExtraArgs}.

%% @doc Entry point of the script
main(Args) ->
    {Command, ParsedArgs, Extra} = parse_and_command(Args),

    SuggestedLogLevel = list_to_atom(proplists:get_value(log_level, ParsedArgs)),
    LogLevel = case lists:member(SuggestedLogLevel, [debug, info, notice, warning,
        error, critical, alert, emergency]) of
                   true -> SuggestedLogLevel;
                   _ -> notice
               end,
    logger:remove_handler(default),
    logger:add_handler(hocon_cli, logger_std_h,
        #{config => #{type => standard_io},
            formatter => {logger_formatter,
                #{legacy_header => false,
                    single_line => true,
                    template => ?FORMAT_TEMPLATE}},
            filter_default => log,
            filters => [],
            level => all
        }),

    logger:set_primary_config(level, LogLevel),
    case Command of
        help ->
            print_help();
        get ->
            get(ParsedArgs, Extra);
        generate ->
            generate(ParsedArgs);
        now_time ->
            now_time();
        _Other ->
            print_help()
    end.

%% equav command: date -u +"%Y.%m.%d.%H.%M.%S"
now_time() ->
    {{Y, M, D}, {HH, MM, SS}} = calendar:local_time(),
    ?STDOUT("~p.~2..0b.~2..0b.~2..0b.~2..0b.~2..0b", [Y, M, D, HH, MM, SS]).

is_valid_now_time(T) ->
    re:run(T, "^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{2}$") =/= nomatch.

-spec get([proplists:property()], [string()]) -> no_return().
get(_ParsedArgs, []) ->
    %% No query, you get nothing.
    ?STDOUT("hocon's get command requires a variable to query.", []),
    ?STDOUT("Try `get setting.name`", []),
    stop_deactivate();
get(ParsedArgs, [Query | _]) ->
    Schema = load_schema(ParsedArgs),
    Conf = load_conf(ParsedArgs, fun log_for_get/3),
    %% map only the desired root name
    [RootName0 | _] = string:tokens(Query, "."),
    RootName = hocon_schema:find_struct(Schema, RootName0),
    %% do not log anything for `get` commands
    DummyLogger = #{logger => fun(_, _) -> ok end},
    {_, NewConf} = hocon_schema:map(Schema, Conf, [RootName], DummyLogger),
    ?STDOUT("~p", [hocon_schema:get_value(Query, NewConf)]),
    stop_ok().

load_schema(ParsedArgs) ->
    case {proplists:get_value(schema_file, ParsedArgs),
          proplists:get_value(schema_module, ParsedArgs)} of
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
    LogFunc(debug, "ConfFiles: ~p", [ConfFiles]),
    case hocon:files(ConfFiles, #{format => richmap}) of
        {error, E} ->
            LogFunc(error, "~p~n", [E]),
            stop_deactivate();
        {ok, Conf} ->
            Conf
    end.

-spec writable_destination_path([proplists:property()]) -> file:filename() | error.
writable_destination_path(ParsedArgs) ->
    EtcDir = proplists:get_value(etc_dir, ParsedArgs),
    DestinationPath = proplists:get_value(dest_dir, ParsedArgs, filename:join(EtcDir, "generated")),
    AbsoluteDestPath = case DestinationPath of
                           [$/ | _] -> DestinationPath;
                           _      -> filename:join(element(2, file:get_cwd()), DestinationPath)
                       end,
    %% Check Permissions
    case filelib:ensure_dir(filename:join(AbsoluteDestPath, "weaksauce.dummy")) of
        %% filelib:ensure_dir/1 requires a dummy filename in the argument,
        %% I think that is weaksauce, hence "weaksauce.dummy"
        ok ->
            AbsoluteDestPath;
        {error, E} ->
            log(error, "Error creating ~s: ~s",
                [AbsoluteDestPath, file:format_error(E)]),
            error
    end.

-spec generate([proplists:property()]) -> ok.
generate(ParsedArgs) ->
    AbsPath = case writable_destination_path(ParsedArgs) of
                  error -> stop_deactivate();
                  Path -> Path
              end,

    DestFile = proplists:get_value(dest_file, ParsedArgs),

    NowTime = proplists:get_value(now_time, ParsedArgs, ""),
    case is_valid_now_time(NowTime) of
        true -> ok;
        false ->
            log(error, "bad -t|--now_time option, get it from this script's now_time command", []),
            stop_deactivate()
    end,

    DestinationFilename = filename_maker(DestFile, NowTime, "config"),
    Destination = filename:join(AbsPath, DestinationFilename),

    DestinationVMArgsFilename = filename_maker("vm", NowTime, "args"),
    DestinationVMArgs = filename:join(AbsPath, DestinationVMArgsFilename),
    log(debug, "Generating config in: ~p", [Destination]),

    Schema = load_schema(ParsedArgs),
    Conf = load_conf(ParsedArgs, fun log/3),
    LogFun = case proplists:get_value(verbose_env, ParsedArgs) of
                 true -> fun log_for_generator/2;
                 false -> fun(_, _) -> ok end
             end,
    try hocon_schema:generate(Schema, Conf, #{logger => LogFun}) of
        NewConfig ->
            AppConfig = proplists:delete(vm_args, NewConfig),
            VmArgs = stringify(proplists:get_value(vm_args, NewConfig)),

            %% Prune excess files
            MaxHistory = proplists:get_value(max_history, ParsedArgs, 3) - 1,
            prune(Destination, MaxHistory),
            prune(DestinationVMArgs, MaxHistory),

            case { file:write_file(Destination, io_lib:fwrite("~p.\n", [AppConfig])),
                   file:write_file(DestinationVMArgs, string:join(VmArgs, "\n"))} of
                {ok, ok} ->
                    ok;
                {Err1, Err2} ->
                    maybe_log_file_error(Destination, Err1),
                    maybe_log_file_error(DestinationVMArgs, Err2),
                    stop_deactivate()
            end
    catch
        throw : Errors ->
            lists:foreach(fun(E) -> log(error, "~p", [E]) end, Errors),
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

    delete([ filename:join([Path, F]) || F <- Files], MaxHistory),
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
        {error, Reason} ->
            log(error, "Could not delete ~s, ~p", [File, Reason])
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
    [ stringify_line(K, V) || {K, V} <- VMArgsProplist ].


stringify_line(K, V) when is_list(V) ->
    io_lib:format("~s ~s", [K, V]);
stringify_line(K, V) ->
    io_lib:format("~s ~w", [K, V]).

log_for_generator(_Level, #{hocon_env_var_name := Var, path := P, value := V}) ->
    ?STDOUT("~s = ~p -> ~s", [Var, V, P]);
log_for_generator(debug, _Args) -> ok;
log_for_generator(info, _Args) -> ok;
log_for_generator(Level, Args) ->
    io:format(standard_error, "[~p] ~p~n", [Level, Args]).

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
        "1" -> ?STDERR("[~p]: " ++ Fmt, [L | Args]);
        _ -> ok
    end;
log_for_get(L, Fmt, Args) ->
    ?STDERR("[~p]: " ++ Fmt, [L | Args]).
