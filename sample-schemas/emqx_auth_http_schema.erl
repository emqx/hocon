-module(emqx_auth_http_schema).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-export([roots/0, fields/1, translations/0, translation/1]).

roots() -> ["auth"].

fields("auth") ->
    [ {"http", emqx_schema:ref("http")}];

fields("http") ->
    [ {"auth_req", emqx_schema:ref("req")}
    , {"super_req", emqx_schema:ref("req")}
    , {"acl_req", emqx_schema:ref("req")}
    , {"timeout", emqx_schema:t(emqx_schema:duration(), "emqx_auth_http.timeout", "5s")}
    , {"connect_timeout", emqx_schema:t(emqx_schema:duration(), "emqx_auth_http.connect_timeout", "5s")}
    , {"pool_size", emqx_schema:t(integer(), "emqx_auth_http.pool_size", 8)}
    , {"ssl", emqx_schema:ref("ssl")}];

fields("req") ->
    [ {"url", emqx_schema:t(string(), undefined, undefined)}
    , {"method", emqx_schema:t(union(get, post), undefined, post)}
    , {"headers", emqx_schema:ref("headers")}
    , {"params", emqx_schema:t(string(), undefined, undefined)}
    ];

fields("headers") ->
    [ {"$field", emqx_schema:t(string(), undefined, undefined)}];

% @TODO modify emqx_auth_http_app.erl
fields("ssl") ->
    emqx_schema:ssl("emqx_auth_http", #{verify => verify_none}).

translations() -> ["emqx_auth_http"].

translation("emqx_auth_http") ->
    [ {"auth_req", fun tr_auth_req/1}
    , {"super_req", fun tr_super_req/1}
    , {"acl_req", fun tr_acl_req/1}
    ].

tr_auth_req(Conf) -> tr_req(Conf, "auth_req").
tr_super_req(Conf) -> tr_req(Conf, "super_req").
tr_acl_req(Conf) -> tr_req(Conf, "acl_req").

tr_req(Conf, Kind) ->
    case emqx_schema:conf_get(["auth.http", Kind, "url"], Conf) of
        undefined -> undefined;
        Url ->
            Headers = emqx_schema:keys(["auth.http", Kind, "headers"], Conf),
            Params = emqx_schema:conf_get(["auth.http", Kind, "params"], Conf),
            [{url, Url},
             {method, emqx_schema:conf_get(["auth.http", Kind, "method"], Conf)},
             {headers, [{H, emqx_schema:conf_get(["auth.http", Kind, "headers", H], Conf)} || H <- Headers]},
             {params, [list_to_tuple(string:tokens(S, "=")) || S <- string:tokens(Params, ",")]}]
    end.
