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
    , ?_assertEqualPlist(load_cuttlefish(tp("logger_disabled.conf")),
                         load_hocon(tp("logger_disabled.conf")))
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

http_test_() ->
    [ ?_assertEqualPlist(load_cuttlefish(tp("http.cuttlefish.conf"),
                                         ss("emqx_auth_http.schema")),
                         load_hocon(tp("http.conf"), emqx_auth_http_schema))
    ].

jwt_test_() ->
    [ ?_assertEqualPlist(load_cuttlefish(tp("jwt.cuttlefish.conf"),
                                         ss("emqx_auth_jwt.schema")),
                         load_hocon(tp("jwt.conf"), emqx_auth_jwt_schema))
    ].

ldap_test_() ->
    [ ?_assertEqualPlist(load_cuttlefish(tp("ldap.cuttlefish.conf"),
                                         ss("emqx_auth_ldap.schema")),
                         load_hocon(tp("ldap.conf"), emqx_auth_ldap_schema))
    , ?_assertEqualPlist(load_cuttlefish(tp("ldap_filters.cuttlefish.conf"),
                                         ss("emqx_auth_ldap.schema")),
                         load_hocon(tp("ldap_filters.conf"), emqx_auth_ldap_schema))
    , ?_assertEqual(lists:keyfind(filters, 1,
                        sub(emqx_auth_ldap, load_cuttlefish(tp("ldap_filters.cuttlefish.conf"),
                                                            ss("emqx_auth_ldap.schema")))),
                    lists:keyfind(filters, 1,
                        sub(emqx_auth_ldap, load_hocon(tp("ldap_filters.conf"),
                                                       emqx_auth_ldap_schema))))
    ].

mnesia_test_() ->
    [ ?_assertEqualPlist(load_cuttlefish(tp("mnesia.cuttlefish.conf"),
                                         ss("emqx_auth_mnesia.schema")),
                         load_hocon(tp("mnesia.conf"), emqx_auth_mnesia_schema))
    ].

mysql_test_() ->
    [ ?_assertEqualPlist(load_cuttlefish(tp("mysql.cuttlefish.conf"),
                                         ss("emqx_auth_mysql.schema")),
                         load_hocon(tp("mysql.conf"), emqx_auth_mysql_schema))
    ].

pgsql_test_() ->
    [ ?_assertEqualPlist(load_cuttlefish(tp("pgsql.cuttlefish.conf"),
                                         ss("emqx_auth_pgsql.schema")),
                         load_hocon(tp("pgsql.conf"), emqx_auth_pgsql_schema))
    ].

redis_test_() ->
    [ ?_assertEqualPlist(load_cuttlefish(tp("redis.cuttlefish.conf"),
                                         ss("emqx_auth_redis.schema")),
                         load_hocon(tp("redis.conf"), emqx_auth_redis_schema))
    ].

mongo_test_() ->
    [ ?_assertEqualPlist(sub(acl_query,
                             sub(emqx_auth_mongo,
                                 load_cuttlefish(tp("mongo.cuttlefish.conf"),
                                     ss("emqx_auth_mongo.schema")))),
                         sub(acl_query,
                             sub(emqx_auth_mongo,
                                 load_hocon(tp("mongo.conf"), emqx_auth_mongo_schema))))
    , ?_assertEqualPlist(sub(mongodb,
                             load_cuttlefish(tp("mongo.cuttlefish.conf"),
                                 ss("emqx_auth_mongo.schema"))),
                         sub(mongodb, load_hocon(tp("mongo.conf"), emqx_auth_mongo_schema)))
    ].

management_test_() ->
    [ ?_assertEqualPlist(load_cuttlefish(tp("management.cuttlefish.conf"),
                                         ss("emqx_management.schema")),
                         load_hocon(tp("management.conf"), emqx_management_schema))
    ].

load_hocon(File) ->
    {ok, C} = hocon:load(File, #{format => richmap}),
    hocon_tconf:generate(emqx_schema, C).

load_hocon(File, Schema) ->
    {ok, C} = hocon:load(File, #{format => richmap}),
    hocon_tconf:generate(Schema, C).

load_cuttlefish(File) ->
    cuttlefish_generator:map(cuttlefish_schema:files(["sample-schemas/emqx.schema"]),
                             cuttlefish_conf:file(File)).

load_cuttlefish(File, Schema) ->
    cuttlefish_generator:map(cuttlefish_schema:files([Schema]),
        cuttlefish_conf:file(File)).

tp(File) ->
    filename:join("test/compatibility", File).

ss(File) ->
    filename:join("sample-schemas", File).

% get sub-proplist
sub(Key, Plist) ->
    proplists:get_value(Key, Plist).

sort_nested_plist([X | _] = Plist) when is_tuple(X) ->
    ChildrenSorted = [sort_nested_plist(KV) || KV <- Plist],
    lists:sort(ChildrenSorted);
sort_nested_plist({K, V}) ->
    {K, sort_nested_plist(V)};
sort_nested_plist({A, B, V}) ->
    {A, B, sort_nested_plist(V)};
sort_nested_plist(L) when is_list(L) ->
    lists:sort(L);
sort_nested_plist(Other)->
    Other.
