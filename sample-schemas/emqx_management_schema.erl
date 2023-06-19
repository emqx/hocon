-module(emqx_management_schema).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-type endpoint() :: string() | integer() .
-type verify() :: verify_peer | verify_none.

-reflect_type([endpoint/0, verify/0]).

-export([roots/0, fields/1, translations/0, translation/1]).

roots() -> ["management"].

fields("management") ->
    [ {"max_row_limit", emqx_schema:t(integer(), "emqx_management.max_row_limit", 10000)}
    , {"default_application", emqx_schema:ref("default_application")}
    , {"default_application_secret", emqx_schema:t(string(), "emqx_management.default_application_secret", undefined)}
    , {"application", emqx_schema:ref("application")}
    , {"listener", emqx_schema:ref("listener")}];

fields("default_application") ->
    [ {"id", emqx_schema:t(string(), "emqx_management.default_application_id", undefined)}
    , {"secret", emqx_schema:t(string(), "emqx_management.default_application_secret", undefined)}
    ];

fields("application") ->
    [ {"default_secret", emqx_schema:t(string(), undefined, undefined)}];

fields("listener") ->
    [ {"http", emqx_schema:ref("http")}
    , {"https", emqx_schema:ref("https")}
    ];

fields("http") ->
    [ {"endpoint", fun (type) -> endpoint(); (_) -> undefined end}
    , {"acceptors", emqx_schema:t(integer(), undefined, 4)}
    , {"max_clients", emqx_schema:t(integer(), undefined, 512)}
    , {"backlog", emqx_schema:t(integer(), undefined, 1024)}
    , {"send_timeout", emqx_schema:t(emqx_schema:duration(), undefined, "15s")}
    , {"send_timeout_close", emqx_schema:t(emqx_schema:flag(), undefined, true)}
    , {"recbuf", emqx_schema:t(emqx_schema:bytesize(), undefined, undefined)}
    , {"sndbuf", emqx_schema:t(emqx_schema:bytesize(), undefined, undefined)}
    , {"buffer", emqx_schema:t(emqx_schema:bytesize(), undefined, undefined)}
    , {"tune_buffer", emqx_schema:t(emqx_schema:flag(), undefined, undefined)}
    , {"nodelay", emqx_schema:t(boolean(), undefined, true)}
    , {"inet6", emqx_schema:t(boolean(), undefined, false)}
    , {"ipv6_v6only", emqx_schema:t(boolean(), undefined, false)}
    ];

fields("https") ->
    emqx_schema:ssl(undefined, #{}) ++ fields("http").

translations() -> ["emqx_management"].

translation("emqx_management") ->
    [ {"application", fun tr_application/1}
    , {"listeners", fun tr_listeners/1}
    ].

tr_application(Conf) ->
    Opts = filter([{default_secret, emqx_schema:conf_get("management.application.default_secret", Conf)}]),
    Transfer = fun(default_secret, V) -> list_to_binary(V);
                  (_, V) -> V
               end,
    case [{K, Transfer(K, V)}|| {K, V} <- Opts] of
        [] -> undefined;
        Sth -> Sth
    end.

tr_listeners(Conf) ->
    Opts = fun(Prefix) ->
        filter([{num_acceptors,   emqx_schema:conf_get(Prefix ++ ".acceptors", Conf)},
                {max_connections, emqx_schema:conf_get(Prefix ++ ".max_clients", Conf)}])
           end,
    TcpOpts = fun(Prefix) ->
        filter([{backlog, emqx_schema:conf_get(Prefix ++ ".backlog", Conf)},
                {send_timeout, emqx_schema:conf_get(Prefix ++ ".send_timeout", Conf)},
                {send_timeout_close, emqx_schema:conf_get(Prefix ++ ".send_timeout_close", Conf)},
                {recbuf,  emqx_schema:conf_get(Prefix ++ ".recbuf", Conf)},
                {sndbuf,  emqx_schema:conf_get(Prefix ++ ".sndbuf", Conf)},
                {buffer,  emqx_schema:conf_get(Prefix ++ ".buffer", Conf)},
                {nodelay, emqx_schema:conf_get(Prefix ++ ".nodelay", Conf, true)},
                {inet6, emqx_schema:conf_get(Prefix ++ ".inet6", Conf)},
                {ipv6_v6only, emqx_schema:conf_get(Prefix ++ ".ipv6_v6only", Conf)}])
              end,

    lists:foldl(
        fun(Proto, Acc) ->
            Prefix = "management.listener." ++ atom_to_list(Proto),
            case emqx_schema:conf_get(Prefix ++ ".endpoint", Conf) of
                undefined -> Acc;
                Port ->
                    [{Proto, Port, TcpOpts(Prefix) ++ Opts(Prefix)
                        ++ case Proto of
                               http -> [];
                               https -> emqx_schema:tr_ssl(Prefix, Conf)
                           end} | Acc]
            end
        end, [], [http, https]).

%% helpers

filter(Opts) ->
    [{K, V} || {K, V} <- Opts, V =/= undefined].
