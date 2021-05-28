-module(emqx_auth_redis_schema).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-export([structs/0, fields/1, translations/0, translation/1]).

structs() -> ["auth"].

fields("auth") ->
    [ {"redis", emqx_schema:ref("redis")}];

fields("redis") ->
    [ {"type", t(union([single, sentinel, cluster]), undefined, single)}
    , {"server", t(string(), undefined, "127.0.0.1:6379")}
    , {"sentinel", t(string(), undefined, "")}
    , {"pool", t(integer(), undefined, 8)}
    , {"database", t(integer(), undefined, 0)}
    , {"password", t(string(), undefined, "")}
    , {"ssl", emqx_schema:ref("ssl")}
    , {"query_timeout", t(union(infinity, emqx_schema:duration()), "emqx_auth_redis.query_timeout", infinity)}
    , {"auth_cmd", t(string(), "emqx_auth_redis.auth_cmd", undefined)}
    , {"password_hash", t(emqx_schema:comma_separated_list(), undefined, undefined)}
    , {"super_cmd", t(string(), "emqx_auth_redis.super_cmd", undefined)}
    , {"acl_cmd", t(string(), "emqx_auth_redis.acl_cmd", undefined)}];

fields("ssl") ->
    emqx_schema:ssl(undefined, #{enable => false, verify => verify_none}).

translations() -> ["emqx_auth_redis"].

translation("emqx_auth_redis") ->
    [ {"server", fun tr_server/1}
    , {"options", fun tr_options/1}
    , {"password_hash", fun tr_password_hash/1}
    ].

tr_options(Conf) ->
    case emqx_schema:tr_ssl("auth.redis.ssl", Conf) of
        [] ->
            [{options, []}];
        Opts ->
            [{options, [{ssl_options, Opts}]}]
    end.

tr_server(Conf) ->
    Fun = fun(S) ->
        case string:split(S, ":", trailing) of
            [Domain]       -> {Domain, 6379};
            [Domain, Port] -> {Domain, list_to_integer(Port)}
        end
          end,
    Servers = emqx_schema:conf_get("auth.redis.server", Conf),
    Type = emqx_schema:conf_get("auth.redis.type", Conf),
    Server = case Type of
                 single ->
                     {Host, Port} = Fun(Servers),
                     [{host, Host}, {port, Port}];
                 _ ->
                     S = string:tokens(Servers, ","),
                     [{servers, [Fun(S1) || S1 <- S]}]
             end,
    [{type, Type},
     {pool_size, emqx_schema:conf_get("auth.redis.pool", Conf)},
     {auto_reconnect, 1},
     {database, emqx_schema:conf_get("auth.redis.database", Conf)},
     {password, emqx_schema:conf_get("auth.redis.password", Conf)},
     {sentinel, emqx_schema:conf_get("auth.redis.sentinel", Conf)}] ++ Server.

tr_password_hash(Conf) ->
    emqx_schema:tr_password_hash("auth.redis", Conf).

t(T, M, D) -> emqx_schema:t(T, M, D).
