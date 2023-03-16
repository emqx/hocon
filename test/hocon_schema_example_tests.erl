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

-module(hocon_schema_example_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("typerefl/include/types.hrl").

-include_lib("hocon/include/hoconsc.hrl").

-export([
    roots/0,
    fields/1,
    tags/0,
    namespace/0
]).

namespace() -> example.
roots() -> ["example"].
tags() -> [<<"tag1">>, <<"another tag">>].

fields("example") ->
    Element = #{
        <<"test">> => 999,
        <<"test1">> =>
            #{
                <<"http">> =>
                    #{
                        <<"backlog">> => 1023,
                        <<"enable">> => true,
                        <<"inet6">> => true,
                        <<"ipv6_v6only">> => true,
                        <<"send_timeout">> => <<"10s">>
                    }
            }
    },
    MapExample = #{
        <<"good">> => Element
    },
    Union = hoconsc:union([?R_REF(emqx_schema, "mcast"), ?R_REF(emqx_schema, "etcd")]),
    UnionExample = #{test => #{value => #{addr => <<"127.0.0.1">>, ttl => 100}}},
    [
        {key1,
            ?HOCON(
                ?R_REF("base"),
                #{desc => <<"base test">>}
            )},
        {map_key1, ?HOCON(hoconsc:map(map_name1, ?REF("map_name")), #{example1s => MapExample})},
        {map_key2, ?HOCON(hoconsc:map(map_name2, ?REF("map_name")), #{})},
        {union_key, ?HOCON(Union, #{examples => UnionExample})},
        {union_key2, Union},
        {array_key, hoconsc:array(?R_REF(emqx_schema, "mcast"))},
        {array_key2, hoconsc:array(?R_REF(emqx_schema, "etcd"))},
        {array_key3, hoconsc:array(integer())},
        {array_key4, hoconsc:array(integer())},
        {array_key5, ?HOCON(hoconsc:array(?R_REF("map_name")), #{examples => [Element]})}
    ];
fields("base") ->
    [
        {"http",
            ?HOCON(
                ?R_REF("http"),
                #{
                    desc => "TCP listeners",
                    required => {false, recursively}
                }
            )},
        {"https",
            ?HOCON(
                ?R_REF("https"),
                #{
                    desc => "SSL listeners",
                    required => {false, recursively}
                }
            )}
    ];
fields("http") ->
    [
        enable(true),
        bind(18803)
        | common_listener_fields()
    ];
fields("https") ->
    [
        enable(false),
        bind(18804)
        | common_listener_fields()
    ];
fields("map_name") ->
    [
        {test, ?HOCON(integer(), #{})},
        {test1, ?HOCON(?R_REF("base"), #{})}
    ].

common_listener_fields() ->
    [
        {"num_acceptors",
            ?HOCON(
                integer(),
                #{
                    default => 4,
                    desc => <<"num_acceptors">>
                }
            )},
        {"max_connections",
            ?HOCON(
                integer(),
                #{
                    default => 512,
                    desc => <<"max_connections">>
                }
            )},
        {"backlog",
            ?HOCON(
                integer(),
                #{
                    default => 1024,
                    desc => <<"backlog">>
                }
            )},
        {"send_timeout",
            ?HOCON(
                emqx_schema:duration(),
                #{
                    default => "5s",
                    desc => <<"send_timeout">>
                }
            )},
        {"inet6",
            ?HOCON(
                boolean(),
                #{
                    default => false,
                    desc => <<"inet6">>
                }
            )},
        {"ipv6_v6only",
            ?HOCON(
                boolean(),
                #{
                    default => false,
                    desc => <<"ipv6_v6only">>
                }
            )}
    ].

enable(Bool) ->
    {"enable",
        ?HOCON(
            boolean(),
            #{
                default => Bool,
                required => true,
                desc => <<"listener_enable">>
            }
        )}.

bind(Port) ->
    {"bind",
        ?HOCON(
            hoconsc:union([non_neg_integer(), emqx_schema:ip_port()]),
            #{
                default => Port,
                required => true,
                extra => #{example => [Port, "0.0.0.0:" ++ integer_to_list(Port)]},
                desc => <<"bind">>
            }
        )}.

no_crash_test_() ->
    [
        {"example", gen(?MODULE)},
        {"demo_schema", gen(demo_schema, "./test/data/demo_schema_doc.conf")},
        {"demo_schema2", gen(demo_schema2)},
        {"demo_schema3", gen(demo_schema3)},
        {"emqx_schema", gen(emqx_schema)},
        {"arbitrary1",
            gen(#{
                namespace => dummy,
                roots => [foo],
                fields => #{foo => [{"f1", hoconsc:enum([bar])}]}
            })},
        {"arbitrary2",
            gen(#{
                namespace => dummy,
                roots => [foo],
                fields => #{foo => [{"f1", hoconsc:mk(hoconsc:ref(emqx_schema, "zone"))}]}
            })},
        {"multi-line-default",
            gen(#{
                namespace => "rootns",
                roots => [foo],
                fields => #{
                    foo => [
                        {"f1",
                            hoconsc:mk(
                                hoconsc:ref(emqx_schema, "etcd"),
                                #{
                                    default => #{
                                        <<"server">> => <<"localhost">>,
                                        <<"prefix">> => <<"prefix">>,
                                        <<"node_ttl">> => "100s",
                                        <<"ssl">> => <<>>
                                    }
                                }
                            )}
                    ]
                }
            })}
    ].

gen(Schema) -> fun() -> hocon_schema_example:gen(Schema, "test") end.
gen(Schema, DescFile) ->
    fun() ->
        hocon_schema_example:gen(
            Schema,
            #{title => "test", body => <<>>, desc_file => DescFile}
        )
    end.
