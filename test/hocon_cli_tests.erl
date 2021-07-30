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

-module(hocon_cli_tests).

-include_lib("eunit/include/eunit.hrl").


-define(assertPrinted(___Text),
    (fun() ->
        case cuttlefish_test_group_leader:get_output() of
            {ok, ___Output} ->
                case re:run(___Output, ___Text) of
                    {match, _} ->
                        ok;
                    nomatch ->
                        erlang:error({assertPrinted_failed,
                                     [{module, ?MODULE},
                                      {line, ?LINE},
                                      {expected, ___Text},
                                      {actual, unicode:characters_to_list(___Output)}]})
                end;
            error ->
                erlang:error({assertPrinted_failed,
                             [{module, ?MODULE},
                              {line, ?LINE},
                              {expected, ___Text},
                              {reason, timed_out_on_receive}]})
        end
    end)()).

-define(CAPTURING(__Forms),
    (fun() ->
        ___OldLeader = group_leader(),
        group_leader(cuttlefish_test_group_leader:new_group_leader(self()), self()),
        try
            __Forms
        after
            cuttlefish_test_group_leader:tidy_up(___OldLeader)
        end
     end)()).

generate_config_test_() ->
    Output = [{app_foo, [{range, {1, 10}}, {setting, "hello"}]}],
    Gen = fun(T, Sc) ->
             hocon_cli:main(["-c", etc("demo-schema-example-1.conf")]
                             ++ generate_opts(T) ++ Sc)
          end,
    [fun() ->
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
             hocon_cli:main(["-c", etc("demo-schema-failure.conf")]
                             ++ generate_opts(T) ++ Sc)
          end,
    Time = now_time(),
    SchemaModule = "demo_schema", %% not demo_schema, so the check will fail
    ?assertThrow(stop_deactivate, Gen(Time, ["-s", SchemaModule])).


generate_multiple_input_config_test() ->
    Time = now_time(),
    hocon_cli:main(["-s", "demo_schema",
                    "-c", etc("demo-schema-example-2.conf"),
                    "-c", etc("demo-schema-example-3.conf")
                    ] ++ generate_opts(Time)),
    {ok, [[{app_foo, Plist}]]} = file:consult(config_fname(Time)),
    ?assertEqual("yaa", proplists:get_value(setting, Plist)).

generate_opts(T) -> ["-t", T, "-d", out(), "generate"].

now_time_test() ->
    ?CAPTURING(begin
                   hocon_cli:main(["now_time"]),
                   {ok, Stdout} = cuttlefish_test_group_leader:get_output(),
                   ?assert(hocon_cli:is_valid_now_time(Stdout))
               end).

generate_with_env_logging_test() ->
    ?CAPTURING(begin
                   Time = now_time(),
                   with_envs(fun hocon_cli:main/1,
                             [["-c", etc("demo-schema-example-1.conf"),
                               "-s", "demo_schema",
                               "-t", Time,
                               "-d", out(),
                               "--verbose_env", "generate"
                               ]],
                             [{"ZZZ_FOO__MIN", "42"}, {"ZZZ_FOO__MAX", "43"},
                              {"HOCON_ENV_OVERRIDE_PREFIX", "ZZZ_"}]),
                   {ok, Stdout} = cuttlefish_test_group_leader:get_output(),
                   ?assertEqual([<<"ZZZ_FOO__MAX = 43 -> foo.max">>,
                                 <<"ZZZ_FOO__MIN = 42 -> foo.min">>],
                                lists:sort(binary:split(iolist_to_binary(Stdout),
                                                        <<"\n">>, [global, trim])))
               end).

generate_vmargs_test() ->
    ?CAPTURING(begin
                   Time = now_time(),
                   hocon_cli:main(["-c", etc("demo-schema-example-2.conf"),
                                   "-t", Time,
                                   "-d", out(),
                                   "-s", "demo_schema",
                                   "generate"]),
                   {ok, Config} = file:read_file(vmargs_fname(Time)),
                   ?assertEqual(<<"-env ERL_MAX_PORTS 64000\n-name emqx@127.0.0.1">>, Config)
               end).

get_test_() ->
    [ {"`get` output is correct", fun get_basic/0}
    , {"`get` respect env var", fun get_env/0}
    ].

get_basic() ->
    ?CAPTURING(begin
                   hocon_cli:main(["-c", etc("demo-schema-example-1.conf"),
                                   "-s", "demo_schema", "get", "foo.setting"]),
                   ?assertPrinted("\"hello\"")
               end).

get_env() ->
        ?CAPTURING(begin
                   with_envs(fun hocon_cli:main/1,
                                [["-c", etc("demo-schema-example-2.conf"),
                                   "-s", "demo_schema", "get", "foo.setting"]],
                                [{"EMQX_FOO__SETTING", "hi"},
                                 {"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"}]),
                   ?assertPrinted("\"hi\"")
                   end).

prune_test() ->
    GenDir = out(),
    case file:list_dir(out()) of
        {ok, FilenamesToDelete} ->
            [file:delete(filename:join([GenDir, F])) || F <- FilenamesToDelete];
        _ -> ok
    end,

    ExpectedMax = 2,

    Cli = fun () -> hocon_cli:main(["-i", ss("demo_schema.erl"),
                                    "-c", etc("demo-schema-example-1.conf"),
                                    "--now_time", now_time(),
                                    "-m", integer_to_list(ExpectedMax),
                                    "-d", out()]) end,
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
