-module(emqx_auth_pgsql_schema).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-export([roots/0, fields/1, translations/0, translation/1]).

roots() -> ["auth"].

fields("auth") ->
    [ {"pgsql", emqx_schema:ref("pgsql")}];

fields("pgsql") ->
    [ {"server", t(string(), undefined, "127.0.0.1:5432")}
    , {"pool", t(integer(), undefined, 8)}
    , {"username", t(string(), undefined, "")}
    , {"password", t(string(), undefined, "")}
    , {"database", t(string(), undefined, "mqtt")}
    , {"encoding", t(atom(), undefined, utf8)}
    , {"query_timeout", t(emqx_schema:duration(), undefined, "5s")}
    , {"ssl", emqx_schema:ref("ssl")}
    , {"auth_query", t(string(), "emqx_auth_pgsql.auth_query", undefined)}
    , {"password_hash", t(emqx_schema:comma_separated_list())}
    , {"super_query", t(string(), "emqx_auth_pgsql.super_query", undefined)}
    , {"acl_query", t(string(), "emqx_auth_pgsql.acl_query", undefined)}
    , {"pbkdf2_macfun", t(atom(), "emqx_auth_pgsql.pbkdf2_macfun", undefined)}
    , {"pbkdf2_iterations", t(integer(), "emqx_auth_pgsql.pbkdf2_iterations", undefined)}
    , {"pbkdf2_dklen", t(integer(), "emqx_auth_pgsql.pbkdf2_dklen", undefined)}];

fields("ssl") ->
    emqx_schema:ssl(undefined, #{enable => false,
                                 tls_version => "tlsv1.3,tlsv1.2,tlsv1.1",
                                 verify => verify_none}).

translations() -> ["emqx_auth_pgsql"].

translation("emqx_auth_pgsql") ->
    [ {"server", fun tr_server/1}
    , {"password_hash", fun tr_password_hash/1}].

tr_server(Conf) ->
    {PgHost, PgPort} =
        case emqx_schema:conf_get("auth.pgsql.server", Conf) of
            {Ip, Port} -> {Ip, Port};
            S          -> case string:tokens(S, ":") of
                              [Domain]       -> {Domain, 5432};
                              [Domain, Port] -> {Domain, list_to_integer(Port)}
                          end
        end,

    Ssl = case emqx_schema:tr_ssl("auth.pgsql.ssl", Conf) of
              [] -> [];
              Opts -> [{ssl, true}, {ssl_opts, Opts}]
          end,

    TempHost = case inet:parse_address(PgHost) of
                   {ok, IpAddr} ->
                       IpAddr;
                   _ ->
                       PgHost
               end,
    [{pool_size, emqx_schema:conf_get("auth.pgsql.pool", Conf)},
     {auto_reconnect, 1},
     {host, TempHost},
     {port, PgPort},
     {username, emqx_schema:conf_get("auth.pgsql.username", Conf)},
     {password, emqx_schema:conf_get("auth.pgsql.password", Conf)},
     {database, emqx_schema:conf_get("auth.pgsql.database", Conf)},
     {encoding, emqx_schema:conf_get("auth.pgsql.encoding", Conf)}] ++ Ssl.

tr_password_hash(Conf) ->
    emqx_schema:tr_password_hash("auth.pgsql", Conf).

t(T) -> emqx_schema:t(T).

t(T, M, D) -> emqx_schema:t(T, M, D).
