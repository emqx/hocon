%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon_schema_aliases_tests).

-hank([{unnecessary_function_arguments, [{incr, 2}]}]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-export([
    roots/0,
    fields/1,
    namespace/0
]).

namespace() ->
    aliases.

roots() ->
    [
        {"root1", #{
            aliases => ["old_root1"],
            type => hoconsc:ref(?MODULE, "root1")
        }},
        "root2",
        {"root3", #{type => boolean(), deprecated => {since, "v0"}, aliases => [<<"old_root3">>]}}
    ].

fields("root1") ->
    [
        {key1, hoconsc:mk(integer(), #{required => false})},
        {key2, hoconsc:mk(integer(), #{required => false})}
    ];
fields("root2") ->
    [
        {key2, #{aliases => [old_key2], type => integer()}},
        {key3, string()},
        {key4, #{
            aliases => [old_key4], type => integer(), converter => fun incr/2, required => false
        }}
    ].

%% test a root field can be safely renamed
%% in this case, one of the root level fields in the test schema ?MODULE.
%% old_root1 is renamed to root1
check_root_test() ->
    ConfText = "{old_root1 = {key1 = 1}, root2 = {key2 = 2, key3 = \"foo\"}}",
    {ok, Conf} = hocon:binary(ConfText),
    ?assertEqual(
        #{
            <<"root1">> => #{<<"key1">> => 1},
            <<"root2">> => #{<<"key2">> => 2, <<"key3">> => "foo"}
        },
        hocon_tconf:check_plain(?MODULE, Conf)
    ),
    {ok, RichConf} = hocon:binary(ConfText, #{format => richmap}),
    ?assertEqual(
        #{
            <<"old_root1">> => #{<<"key1">> => 1},
            <<"root1">> => #{<<"key1">> => 1},
            <<"root2">> => #{<<"key2">> => 2, <<"key3">> => "foo"}
        },
        hocon_util:richmap_to_map(hocon_tconf:check(?MODULE, RichConf))
    ).

check_converter_test() ->
    ConfText = "{old_root1 = {key1 = 1}, root2 = {key2 = 2, key3 = \"foo\", old_key4 = 3}}",
    {ok, Conf} = hocon:binary(ConfText),
    ?assertEqual(
        #{
            <<"root1">> => #{<<"key1">> => 1},
            <<"root2">> => #{<<"key2">> => 2, <<"key3">> => "foo", <<"key4">> => 4}
        },
        hocon_tconf:check_plain(?MODULE, Conf)
    ),
    {ok, RichConf} = hocon:binary(ConfText, #{format => richmap}),
    ?assertEqual(
        #{
            <<"old_root1">> => #{<<"key1">> => 1},
            <<"root1">> => #{<<"key1">> => 1},
            <<"root2">> => #{
                <<"key2">> => 2,
                <<"key3">> => "foo",
                <<"old_key4">> => 3,
                <<"key4">> => 4
            }
        },
        hocon_util:richmap_to_map(hocon_tconf:check(?MODULE, RichConf))
    ).

check_field_test() ->
    ConfText =
        "{old_root1 = {key1 = 1}, root2 = {old_key2 = 2, key3 = \"foo\"},"
        "root3 = b, old_root3 = a}",
    {ok, Conf} = hocon:binary(ConfText),
    ?assertEqual(
        #{
            <<"root1">> => #{<<"key1">> => 1},
            <<"root2">> => #{<<"key2">> => 2, <<"key3">> => "foo"}
        },
        hocon_tconf:check_plain(?MODULE, Conf)
    ),
    {ok, RichConf} = hocon:binary(ConfText, #{format => richmap}),
    ?assertEqual(
        #{
            <<"old_root1">> => #{<<"key1">> => 1},
            <<"root1">> => #{<<"key1">> => 1},
            <<"root2">> => #{<<"key2">> => 2, <<"key3">> => "foo", <<"old_key2">> => 2}
            %% deprecated field(old_root3,root3) is not included in the map
            %%<<"old_root3">> => a,
            %% <<"root3">> => b
        },
        hocon_util:richmap_to_map(hocon_tconf:check(?MODULE, RichConf))
    ).

check_env_test() ->
    Fun =
        fun() ->
            ConfText = "{root2 = {key3 = \"foo\"}}",
            {ok, Conf0} = hocon:binary(ConfText),
            Conf = hocon_tconf:merge_env_overrides(?MODULE, Conf0, all, #{format => map}),
            ?assertEqual(
                #{
                    <<"root1">> => #{<<"key1">> => 42},
                    <<"root2">> => #{<<"key2">> => 43, <<"key3">> => "foo", <<"key4">> => 2}
                },
                hocon_tconf:check_plain(?MODULE, Conf)
            ),
            {ok, RichConf} = hocon:binary(ConfText, #{format => richmap}),
            Conf1 = hocon_tconf:merge_env_overrides(?MODULE, RichConf, all, #{format => richmap}),
            ?assertEqual(
                #{
                    <<"root1">> => #{<<"key1">> => 42},
                    <<"old_root1">> => #{<<"key1">> => 42},
                    <<"root2">> => #{
                        <<"key2">> => 43,
                        <<"old_key2">> => 43,
                        <<"key3">> => "foo",
                        <<"key4">> => 2,
                        <<"old_key4">> => 1
                    }
                },
                hocon_util:richmap_to_map(hocon_tconf:check(?MODULE, Conf1))
            )
        end,
    with_envs(
        Fun,
        [],
        envs([
            {"EMQX_OLD_ROOT1__key1", "42"},
            {"EMQX_ROOT2__OLD_KEY2", "43"},
            {"EMQX_ROOT2__OLD_KEY4", "1"}
        ])
    ).

check_mix_env_test() ->
    Fun =
        fun() ->
            ConfText = "{old_root1 = {key1 = 0, key2 = 1}}",
            {ok, Conf0} = hocon:binary(ConfText),
            Conf = hocon_tconf:merge_env_overrides(?MODULE, Conf0, all, #{format => map}),
            ?assertEqual(
                #{
                    <<"root1">> => #{<<"key1">> => 0, <<"key2">> => 2},
                    <<"root2">> => #{<<"key2">> => 42, <<"key3">> => "foo"}
                },
                hocon_tconf:check_plain(?MODULE, Conf)
            ),
            {ok, RichConf} = hocon:binary(ConfText, #{format => richmap}),
            Conf1 = hocon_tconf:merge_env_overrides(?MODULE, RichConf, all, #{format => richmap}),
            ?assertEqual(
                #{
                    <<"root1">> => #{<<"key1">> => 0, <<"key2">> => 2},
                    <<"old_root1">> => #{<<"key1">> => 0, <<"key2">> => 1},
                    <<"root2">> => #{
                        <<"key2">> => 42,
                        <<"old_key2">> => 42,
                        <<"key3">> => "foo"
                    }
                },
                hocon_util:richmap_to_map(hocon_tconf:check(?MODULE, Conf1))
            )
        end,
    with_envs(
        Fun,
        [],
        envs([
            {"EMQX_ROOT1__KEY2", "2"},
            {"EMQX_ROOT2__OLD_KEY2", "42"},
            {"EMQX_ROOT2__KEY3", "foo"}
        ])
    ).

no_value_test() ->
    ConfText = "{root3 = b, old_root3 = a}",
    {ok, Conf} = hocon:binary(ConfText),
    ?assertEqual(#{}, hocon_tconf:check_plain(?MODULE, Conf, #{required => false})).

with_envs(Fun, Args, Envs) ->
    hocon_test_lib:with_envs(Fun, Args, Envs).

envs(Envs) ->
    [{"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"} | Envs].

incr(undefined, _Opts) -> undefined;
incr(Val, _Opts) -> Val + 1.
