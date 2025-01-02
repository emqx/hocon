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
-module(hocon_schema_builtin_tests).
-feature(maybe_expr, enable).

-include_lib("typerefl/include/types.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("hocon_private.hrl").
-include("hoconsc.hrl").

-export([roots/0, fields/1, to_ip_port/1]).

-type ip_port() :: tuple() | integer().

-typerefl_from_string({ip_port/0, ?MODULE, to_ip_port}).
-reflect_type([ip_port/0]).

roots() ->
    [listener].

fields(listener) ->
    [{"bind", hoconsc:mk(ip_port(), #{default => 80})}].

builtin_check_test() ->
    Conf = "listener.bind = 1024",
    ?assertEqual(#{<<"listener">> => #{<<"bind">> => 1024}}, check_plain(Conf)),
    Conf1 = "listener.bind = 0",
    ?assertEqual(#{<<"listener">> => #{<<"bind">> => 0}}, check_plain(Conf1)),
    Conf2 = "listener.bind = 65535",
    ?assertEqual(#{<<"listener">> => #{<<"bind">> => 65535}}, check_plain(Conf2)),
    BadConf1 = "listener.bind = 65536",
    ?assertThrow(
        {?MODULE, [
            #{
                kind := validation_error,
                reason := "port_number_too_large",
                path := "listener.bind"
            }
        ]},
        check_plain(BadConf1)
    ),
    BadConf2 = "listener.bind = -1",
    ?assertThrow(
        {?MODULE, [
            #{
                kind := validation_error,
                reason := "port_number_must_be_positive",
                path := "listener.bind"
            }
        ]},
        check_plain(BadConf2)
    ),
    BadConf3 = "listener.bind = 1883d",
    ?assertThrow(
        {?MODULE, [
            #{
                kind := validation_error,
                reason := "bad_port_number",
                path := "listener.bind"
            }
        ]},
        check_plain(BadConf3)
    ),
    ok.

check_plain(Str) ->
    {ok, Map} = hocon:binary(Str, #{}),
    hocon_tconf:check_plain(?MODULE, Map, #{}).

to_ip_port(Str) ->
    case split_ip_port(Str) of
        {"", Port} ->
            %% this is a local address
            parse_port(Port);
        {MaybeIp, Port} ->
            maybe
                {ok, PortVal} ?= parse_port(Port),
                {ok, IpTuple} ?= inet:parse_address(MaybeIp),
                {ok, {IpTuple, PortVal}}
            else
                {error, _} ->
                    {error, bad_ip_port}
            end;
        _ ->
            {error, bad_ip_port}
    end.

split_ip_port(Str0) ->
    Str = re:replace(Str0, " ", "", [{return, list}, global]),
    case lists:split(string:rchr(Str, $:), Str) of
        %% no colon
        {[], Str} ->
            {"", Str};
        {IpPlusColon, PortString} ->
            IpStr0 = lists:droplast(IpPlusColon),
            case IpStr0 of
                %% drop head/tail brackets
                [$[ | S] ->
                    case lists:last(S) of
                        $] -> {lists:droplast(S), PortString};
                        _ -> error
                    end;
                _ ->
                    {IpStr0, PortString}
            end
    end.

parse_port(Port) ->
    case string:to_integer(string:strip(Port)) of
        {P, ""} when P < 0 -> {error, "port_number_must_be_positive"};
        {P, ""} when P > 65535 -> {error, "port_number_too_large"};
        {P, ""} -> {ok, P};
        _ -> {error, "bad_port_number"}
    end.
