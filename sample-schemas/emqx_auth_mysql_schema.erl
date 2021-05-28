-module(emqx_auth_mysql_schema).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-export([structs/0, fields/1, translations/0, translation/1]).

structs() -> ["auth"].

fields("auth") ->
    [ {"mysql", emqx_schema:ref("mysql")}];

fields("mysql") ->
    [ {"server", t(string(), undefined, "127.0.0.1:3306")}
    , {"pool", t(integer(), undefined, 8)}
    , {"username", t(string(), undefined, "")}
    , {"password", t(string(), undefined, "")}
    , {"database", t(string(), undefined, "mqtt")}
    , {"query_timeout", t(emqx_schema:duration(), undefined, "5s")}
    , {"ssl", emqx_schema:ref("ssl")}
    , {"auth_query", t(string(), "emqx_auth_mysql.auth_query", undefined)}
    , {"password_hash", t(emqx_schema:comma_separated_list())}
    , {"super_query", t(string(), "emqx_auth_mysql.super_query", undefined)}
    , {"acl_query", t(string(), "emqx_auth_mysql.acl_query", undefined)}];

fields("ssl") ->
    emqx_schema:ssl(undefined, #{enable => false, verify => verify_none}).

translations() -> ["emqx_auth_mysql"].

translation("emqx_auth_mysql") ->
    [ {"server", fun tr_server/1}
    , {"password_hash", fun tr_password_hash/1}].

tr_server(Conf) ->
    {MyHost, MyPort} =
        case emqx_schema:conf_get("auth.mysql.server", Conf) of
            {Ip, Port} -> {Ip, Port};
            S          -> case string:tokens(S, ":") of
                              [Domain]       -> {Domain, 3306};
                              [Domain, Port] -> {Domain, list_to_integer(Port)}
                          end
        end,
    Pool = emqx_schema:conf_get("auth.mysql.pool", Conf),
    Username = emqx_schema:conf_get("auth.mysql.username", Conf),
    Passwd = emqx_schema:conf_get("auth.mysql.password", Conf),
    DB = emqx_schema:conf_get("auth.mysql.database", Conf),
    Timeout = emqx_schema:conf_get("auth.mysql.query_timeout", Conf),
    Options = [{pool_size, Pool},
               {auto_reconnect, 1},
               {host, MyHost},
               {port, MyPort},
               {user, Username},
               {password, Passwd},
               {database, DB},
               {encoding, utf8},
               {query_timeout, Timeout},
               {keep_alive, true}],
    Options1 =
        case emqx_schema:tr_ssl("auth.mysql.ssl", Conf) of
            [] ->
                Options;
            SslOpts ->
                Options ++ [{ssl, SslOpts}]
        end,
    case inet:parse_address(MyHost) of
        {ok, IpAddr} when tuple_size(IpAddr) =:= 8 ->
            [{tcp_options, [inet6]} | Options1];
        _ ->
            Options1
    end.

tr_password_hash(Conf) ->
    emqx_schema:tr_password_hash("auth.mysql", Conf).


t(T) -> emqx_schema:t(T).

t(T, M, D) -> emqx_schema:t(T, M, D).
