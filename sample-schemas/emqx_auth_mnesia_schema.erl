-module(emqx_auth_mnesia_schema).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-export([roots/0, fields/1, translations/0, translation/1, namespace/0]).

namespace() -> "auth_mnesia".
roots() -> ["auth"].

fields("auth") ->
    [ {"mnesia", emqx_schema:ref("mnesia")}
    , {"client", hoconsc:map("id", hoconsc:ref("client"))}
    , {"user", hoconsc:map("id", hoconsc:ref("user"))}
    ];

fields("mnesia") ->
    [ {"password_hash", emqx_schema:t(union([plain, md5, sha, sha256, sha512]),
                                      "emqx_auth_mnesia.password_hash", sha256)}];

fields("client") ->
   [ {"clientid", emqx_schema:t(string())}
   , {"password", emqx_schema:t(string())}];

fields("user") ->
    [ {"username", emqx_schema:t(string())}
    , {"password", emqx_schema:t(string())}].

translations() -> ["emqx_auth_mnesia"].

translation("emqx_auth_mnesia") ->
    [ {"clientid_list", fun tr_clientid_list/1}
    , {"username_list", fun tr_username_list/1}].

tr_clientid_list(Conf) ->
    ClientList = emqx_schema:keys("auth.client", Conf),
    lists:foldl(
        fun(Id, AccIn) ->
            [{emqx_schema:conf_get(["auth.client", Id, "clientid"], Conf),
              emqx_schema:conf_get(["auth.client", Id, "password"], Conf)} | AccIn]
        end, [], ClientList).

tr_username_list(Conf) ->
    ClientList = emqx_schema:keys("auth.user", Conf),
    lists:foldl(
        fun(Id, AccIn) ->
            [{emqx_schema:conf_get(["auth.user", Id, "username"], Conf),
              emqx_schema:conf_get(["auth.user", Id, "password"], Conf)} | AccIn]
        end, [], ClientList).
