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

-module(hocon_cuttlefish_compatibility_tests).

-include_lib("eunit/include/eunit.hrl").

-define(_assertEqualPlist(PlistA, PlistB),
        ?_assertEqual(sort_nested_plist(PlistA), sort_nested_plist(PlistB))).

default_test_() ->
    [ ?_assertEqualPlist(load_cuttlefish(tp("default.conf")),
                       load_hocon(tp("default.conf")))
    ].

cluster_test_() ->
    [ ?_assertEqualPlist(sub(ekka, load_cuttlefish(tp("cluster_manual.cuttlefish.conf"))),
                         sub(ekka, load_hocon(tp("cluster_manual.cuttlefish.conf"))))
    , ?_assertEqualPlist(sub(ekka, load_cuttlefish(tp("cluster_static.cuttlefish.conf"))),
                         sub(ekka, load_hocon(tp("cluster_static.conf"))))
    , ?_assertEqualPlist(sub(ekka, load_cuttlefish(tp("cluster_mcast.cuttlefish.conf"))),
                         sub(ekka, load_hocon(tp("cluster_mcast.conf"))))
    , ?_assertEqualPlist(sub(ekka, load_cuttlefish(tp("cluster_dns.cuttlefish.conf"))),
                         sub(ekka, load_hocon(tp("cluster_dns.cuttlefish.conf"))))
    , ?_assertEqualPlist(sub(ekka, load_cuttlefish(tp("cluster_etcd.cuttlefish.conf"))),
                         sub(ekka, load_hocon(tp("cluster_etcd.conf"))))
    , ?_assertEqualPlist(sub(ekka, load_cuttlefish(tp("cluster_k8s.cuttlefish.conf"))),
                         sub(ekka, load_hocon(tp("cluster_k8s.conf"))))
    ].

node_test_() ->
    [ ?_assertEqualPlist(sub(vm_args, load_cuttlefish(tp("node.cuttlefish.conf"))),
                         sub(vm_args, load_hocon(tp("node.conf"))))
    , ?_assertEqualPlist(sub(kernel, load_cuttlefish(tp("node.cuttlefish.conf"))),
                         sub(kernel, load_hocon(tp("node.conf"))))
    , ?_assertEqualPlist(sub(emqx, load_cuttlefish(tp("node.cuttlefish.conf"))),
                         sub(emqx, load_hocon(tp("node.conf"))))
    ].

rpc_test_() ->
    [ ?_assertEqualPlist(sub(emqx, load_cuttlefish(tp("rpc.conf"))),
                         sub(emqx, load_hocon(tp("rpc.conf"))))
    , ?_assertEqualPlist(sub(gen_rpc, load_cuttlefish(tp("rpc.conf"))),
                         sub(gen_rpc, load_hocon(tp("rpc.conf"))))
    ].

log_test_() ->
    [ ?_assertEqualPlist(sub(kernel, load_cuttlefish(tp("logger.cuttlefish.conf"))),
                         sub(kernel, load_hocon(tp("logger.conf"))))
    , ?_assertEqualPlist(sub(lager, load_cuttlefish(tp("logger.cuttlefish.conf"))),
                         sub(lager, load_hocon(tp("logger.conf"))))
    ].

acl_test_() ->
    [ ?_assertEqualPlist(sub(emqx, load_cuttlefish(tp("acl.cuttlefish.conf"))),
                         sub(emqx, load_hocon(tp("acl.conf"))))
    ].

mqtt_test_() ->
    [ ?_assertEqualPlist(sub(emqx, load_cuttlefish(tp("mqtt.conf"))),
                         sub(emqx, load_hocon(tp("mqtt.conf"))))
    ].

zone_test_() ->
    Zone = fun (Name, Conf) -> sub(Name, sub(zones, sub(emqx, Conf))) end,
    [ ?_assertEqualPlist(Zone(external, load_cuttlefish(tp("zone_external.cuttlefish.conf"))),
                         Zone(external, load_hocon(tp("zone_external.conf"))))
    , ?_assertEqualPlist(Zone(internal, load_cuttlefish(tp("zone_internal.cuttlefish.conf"))),
                         Zone(internal, load_hocon(tp("zone_internal.conf"))))
    ].

listener_test_() ->
    Listener = fun (Proto, Name, Conf) ->
        hd([L || L <- sub(listeners, sub(emqx, Conf)),
            maps:get(name, L) =:= Name, maps:get(proto, L) =:= Proto]) end,
    [ ?_assertEqual(Listener(tcp, "external", load_cuttlefish(tp("listener.cuttlefish.conf"))),
                    Listener(tcp, "external", load_hocon(tp("listener.conf"))))
    , ?_assertEqual(Listener(tcp, "internal", load_cuttlefish(tp("listener.cuttlefish.conf"))),
                    Listener(tcp, "internal", load_hocon(tp("listener.conf"))))
    , ?_assertEqual(Listener(ssl, "external", load_cuttlefish(tp("listener.cuttlefish.conf"))),
                    Listener(ssl, "external", load_hocon(tp("listener.conf"))))
    , ?_assertEqual(Listener(ws, "external", load_cuttlefish(tp("listener.cuttlefish.conf"))),
                    Listener(ws, "external", load_hocon(tp("listener.conf"))))
    , ?_assertEqual(Listener(wss, "external", load_cuttlefish(tp("listener.cuttlefish.conf"))),
                    Listener(wss, "external", load_hocon(tp("listener.conf"))))
    ].

misc_test_() ->
    [ ?_assertEqualPlist(sub(emqx, load_cuttlefish(tp("misc.cuttlefish.conf"))),
                         sub(emqx, load_hocon(tp("misc.conf"))))
    ].

load_hocon(File) ->
    {ok, C} = hocon:load(File, #{format => richmap}),
    hocon_schema:generate(emqx_schema, C).

load_cuttlefish(File) ->
    cuttlefish_generator:map(cuttlefish_schema:files(["sample-schemas/emqx.cuttlefish.schema"]),
                             cuttlefish_conf:file(File)).

tp(File) ->
    filename:join("test/compatibility", File).

% get sub-proplist
sub(Key, Plist) ->
    proplists:get_value(Key, Plist).

sort_nested_plist([{_, _} | _] = Plist) ->
    ChildrenSorted = [{K, sort_nested_plist(V)} || {K, V} <- Plist],
    lists:sort(ChildrenSorted);
sort_nested_plist({K, V}) ->
    {K, sort_nested_plist(V)};
sort_nested_plist(Other)->
    Other.
