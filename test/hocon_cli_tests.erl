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

generate_test_() ->
    [
        {"`generate` output is correct", fun generate_basic/0}
    ].

generate_basic() ->
    ?CAPTURING(begin
                   hocon_cli:main(["-i", ss("demo_schema.erl"),
                       "-c", etc("demo-schema-example-1.conf"),
                       "-d", out()]),
                   {ok, Stdout} = cuttlefish_test_group_leader:get_output(),
                   {ok, Config} = file:consult(regexp_config(Stdout)),
                   ?assertEqual([{app_foo, [{range, {1, 10}}, {setting, "hello"}]}], hd(Config))
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
    ?_assert(length(AppConfigs) =:= 2),
    ?_assert(length(VMArgs) =:= 2),

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

regexp_config(StdOut) ->
    {ok, MP} = re:compile("-config (.+config)"),
    {match, Path} = re:run(StdOut, MP, [global, {capture, all_but_first, list}]),
    Path.
