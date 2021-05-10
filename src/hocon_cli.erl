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

-export([main/1]).

-define(STDOUT(Str, Args), io:format(Str ++ "~n", Args)).
-define(FORMAT(Str, Args), io_lib:format(Str, Args)).
-define(FORMAT_TEMPLATE, [time, " [", level, "] ", msg, "\n"]).

-type file_error() :: file:posix()  %% copied from file:format_error/1
                    | badarg
                    | terminated
                    | system_limit
                    | {integer(), module(), term()}.

-elvis([{elvis_style, macro_module_names, disable}]).

-ifndef(TEST).
% @TODO add logger module for test
-define(LOG, logger).
-else.
-define(LOG, logger).
-endif.

cli_options() ->
%% Option Name, Short Code, Long Code, Argument Spec, Help Message
    [
      {help, $h, "help", undefined, "Print this usage page"}
    , {etc_dir, $e, "etc_dir", {string, "/etc"}, "etc dir"}
    , {dest_dir, $d, "dest_dir", string, "specifies the directory to write the config file to"}
    , {dest_file, $f, "dest_file", {string, "app"}, "the file name to write"}
    , {schema_file, $i, "schema_file", string, "schema module"}
    , {conf_file, $c, "conf_file", string, "a cuttlefish conf file, multiple files allowed"}
    , {log_level, $l, "log_level", {string, "notice"}, "log level for cuttlefish output"}
    , {max_history, $m, "max_history", {integer, 3},
        "the maximum number of generated config files to keep"}
    , {verbose_env, $v, "verbose_env", {boolean, false}, "whether to log env overrides to stdout"}
    ].

print_help() ->
    getopt:usage(cli_options(),
        escript:script_name()),
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
    {Command, ParsedArgs, _Extra} = parse_and_command(Args),

    SuggestedLogLevel = list_to_atom(proplists:get_value(log_level, ParsedArgs)),
    LogLevel = case lists:member(SuggestedLogLevel, [debug, info, notice, warning,
        error, critical, alert, emergency]) of
                   true -> SuggestedLogLevel;
                   _ -> notice
               end,
    logger:remove_handler(default),
    logger:add_handler(cuttlefish, logger_std_h,
        #{config => #{type => standard_error},
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
        generate ->
            generate(ParsedArgs);
        _Other ->
            print_help()
    end.

-spec generate([proplists:property()]) -> no_return().
generate(ParsedArgs) ->
    case engage_hocon(ParsedArgs) of
        %% this is nice and all, but currently all error paths of engage_cuttlefish end with
        %% stop_deactivate() hopefully factor that to be cleaner.
        error ->
            stop_deactivate();
        {AppConf, VMArgs} ->
            %% Note: we have added a parameter '-vm_args' to this. It appears redundant
            %% but it is not! the erlang vm allows us to access all arguments to the erl
            %% command EXCEPT '-args_file', so in order to get access to this file location
            %% from within the vm, we need to pass it in twice.
            ?STDOUT(" -config ~s -args_file ~s -vm_args ~s ", [AppConf, VMArgs, VMArgs]),
            stop_ok()
    end.

load_schema(ParsedArgs) ->
    SchemaFile = proplists:get_value(schema_file, ParsedArgs),
    ErlLibs = os:getenv("ERL_LIBS", ""),
    {ok, Module} = compile:file(SchemaFile, [{i, ErlLibs}]),
    Module.

-spec load_conf([proplists:property()]) -> hocon:config() | no_return().
load_conf(ParsedArgs) ->
    ConfFiles = proplists:get_all_values(conf_file, ParsedArgs),
    ?LOG:debug("ConfFiles: ~p", [ConfFiles]),
    case hocon:load(ConfFiles, #{format => richmap}) of
        {error, E} ->
            ?LOG:error("~p~n", [E]),
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
            ?LOG:error(
                "Error creating ~s: ~s",
                [AbsoluteDestPath, file:format_error(E)]),
            error
    end.

-spec engage_hocon([proplists:property()]) -> {string(), string()} | error.
engage_hocon(ParsedArgs) ->
    AbsPath = case writable_destination_path(ParsedArgs) of
                  error ->
                      stop_deactivate(),
                      error;
                  Path -> Path
              end,

    Date = calendar:local_time(),

    DestFile = proplists:get_value(dest_file, ParsedArgs),

    DestinationFilename = filename_maker(DestFile, Date, "config"),
    Destination = filename:join(AbsPath, DestinationFilename),

    DestinationVMArgsFilename = filename_maker("vm", Date, "args"),
    DestinationVMArgs = filename:join(AbsPath, DestinationVMArgsFilename),
    ?LOG:debug("Generating config in: ~p", [Destination]),

    Schema = load_schema(ParsedArgs),
    Conf = load_conf(ParsedArgs),
    LogFun = case proplists:get_value(verbose_env, ParsedArgs) of
                 true ->
                     fun(Key, Value) -> ?STDOUT("~s = ~p", [string:join(Key, "."), Value]) end;
                 false ->
                     fun(_, _) -> ok end
             end,

    case hocon_schema:generate(Schema, Conf) of
        %{error, _X} ->
            % @TODO print error
        %    error;
        NewConfig ->
            AppConfig = proplists:delete(vm_args, NewConfig),
            VmArgs = stringify(proplists:get_value(vm_args, NewConfig)),

            %% Prune excess files
            MaxHistory = proplists:get_value(max_history, ParsedArgs, 3) - 1,
            prune(Destination, MaxHistory),
            prune(DestinationVMArgs, MaxHistory),

            case { file:write_file(Destination, io_lib:fwrite("~p.\n", [AppConfig])),
                file:write_file(DestinationVMArgs, [VmArgs, "\n"])} of
                {ok, ok} ->
                    {Destination, DestinationVMArgs};
                {Err1, Err2} ->
                    maybe_log_file_error(Destination, Err1),
                    maybe_log_file_error(DestinationVMArgs, Err2),
                    error
            end

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
            ?LOG:error("Could not delete ~s, ~p", [File, Reason])
    end,
    do_delete(Files, Left - 1).

-spec maybe_log_file_error(file:filename(), ok | {error, file_error()}) -> ok.
maybe_log_file_error(_, ok) ->
    ok;
maybe_log_file_error(Filename, {error, Reason}) ->
    ?LOG:error("Error writing ~s: ~s", [Filename, file:format_error(Reason)]),
    ok.

filename_maker(Filename, Date, Extension) ->
    {{Y, M, D}, {HH, MM, SS}} = Date,
    _DestinationFilename =
        lists:flatten(io_lib:format("~s.~p.~2..0b.~2..0b.~2..0b.~2..0b.~2..0b.~s",
            [Filename, Y, M, D, HH, MM, SS, Extension])).

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
