-module(emqx_auth_ldap_schema).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-export([roots/0, fields/1, translations/0, translation/1, namespace/0]).

namespace() -> "auth_ldap".
roots() -> ["auth"].

fields("auth") ->
    [ {"ldap", emqx_schema:ref("ldap")}];

fields("ldap") ->
    [ {"servers", t(emqx_schema:comma_separated_list(), undefined, "127.0.0.1")}
    , {"port", t(integer(), undefined, 389)}
    , {"pool", t(integer(), undefined, 8)}
    , {"bind_dn", t(string(), undefined, "cn=root,dc=emqx,dc=io")}
    , {"bind_password", t(string(), undefined, "public")}
    , {"timeout", t(emqx_schema:duration(), undefined, "30s")}
    , {"ssl", emqx_schema:ref("ssl")}
    , {"device_dn", t(string(), "emqx_auth_ldap.device_dn", "ou=device,dc=emqx,dc=io")}
    , {"match_objectclass", t(string(), "emqx_auth_ldap.match_objectclass", "mqttUser")}
    , {"custom_base_dn", t(string(), "emqx_auth_ldap.custom_base_dn", "${username_attr}=${user},${device_dn}")}
    , {"filters", hoconsc:map("num", hoconsc:ref("filter"))}
    , {"bind_as_user", t(boolean(), "emqx_auth_ldap.bind_as_user", false)}
    , {"username_attr", t(string(), "emqx_auth_ldap.username_attr", "uid")}
    , {"password_attr", t(string(), "emqx_auth_ldap.password_attr", "userPassword")}
    ];

fields("ssl") ->
    emqx_schema:ssl(undefined, #{enable => false, verify => verify_none});

fields("filter") ->
    [ {"key", t(string())}
    , {"value", t(string())}
    , {"op", t(union('and', 'or'))}
    ].

translations() -> ["emqx_auth_ldap"].

translation("emqx_auth_ldap") ->
    [ {"ldap", fun tr_ldap/1}
    , {"filters", fun tr_filter/1}].

tr_ldap(Conf) ->
    A2N = fun(A) -> case inet:parse_address(A) of {ok, N} -> N; _ -> A end end,
    Servers = [A2N(A) || A <- emqx_schema:conf_get("auth.ldap.servers", Conf)],
    Port = emqx_schema:conf_get("auth.ldap.port", Conf),
    Pool = emqx_schema:conf_get("auth.ldap.pool", Conf),
    BindDN = emqx_schema:conf_get("auth.ldap.bind_dn", Conf),
    BindPassword = emqx_schema:conf_get("auth.ldap.bind_password", Conf),
    Timeout = emqx_schema:conf_get("auth.ldap.timeout", Conf),
    Opts = [{servers, Servers},
            {port, Port},
            {timeout, Timeout},
            {bind_dn, BindDN},
            {bind_password, BindPassword},
            {pool, Pool},
            {auto_reconnect, 2}],
    case emqx_schema:tr_ssl("auth.ldap.ssl", Conf) of
        [] -> [{ssl, false} | Opts];
        SslOpts -> [{ssl, true}, {sslopts, SslOpts} | Opts]
    end.

tr_filter(Conf) ->
    Field = "auth.ldap.filters",
    Nums = emqx_schema:keys(Field, Conf),
    case do_tr_filter(Nums, Conf, Field, []) of
        [] -> undefined;
        Sth -> Sth
    end.

do_tr_filter([], _, _, _) ->
    [];
do_tr_filter([Num], Conf, Field, Acc) ->
    lists:reverse([{emqx_schema:conf_get([Field, Num, "key"], Conf),
                    emqx_schema:conf_get([Field, Num, "value"], Conf)} | Acc]);
do_tr_filter([Num | More], Conf, Field, Acc) ->
    Field = "auth.ldap.filters",
    do_tr_filter(More, Conf, Field,
        [emqx_schema:conf_get([Field, Num, "op"], Conf),
         {emqx_schema:conf_get([Field, Num, "key"], Conf),
          emqx_schema:conf_get([Field, Num, "value"], Conf)} | Acc]).

t(T) -> emqx_schema:t(T).
t(T, M, D) -> emqx_schema:t(T, M, D).
