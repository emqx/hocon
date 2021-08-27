
-module(emqx_auth_mongo_schema).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-type type() :: single | unknown | sharded | rs.
-type w_mode() :: safe | unsafe | undef.
-type r_mode() :: master | slave_ok | undef.

-reflect_type([type/0, w_mode/0, r_mode/0]).

-export([roots/0, fields/1, translations/0, translation/1]).

roots() -> ["auth"].

fields("auth") ->
    [ {"mongo", emqx_schema:ref("mongo")}];

fields("mongo") ->
    [ {"type", fun type/1}
    , {"rs_set_name", emqx_schema:t(string(), undefined, "mqtt")}
    , {"server", emqx_schema:t(string(), undefined, "127.0.0.1:27017")}
    , {"pool", emqx_schema:t(integer(), undefined, 8)}
    , {"login", emqx_schema:t(string(), undefined, undefined)}
    , {"username", emqx_schema:t(string(), undefined, "")}
    , {"password", emqx_schema:t(string(), undefined, "")}
    , {"database", emqx_schema:t(string(), undefined, "mqtt")}
    , {"auth_source", emqx_schema:t(string(), undefined, "mqtt")}
    , {"ssl", emqx_schema:ref("ssl")}
    , {"w_mode", fun w_mode/1}
    , {"r_mode", fun r_mode/1}
    , {"topology", emqx_schema:ref("topology")}
    , {"query_timeout", emqx_schema:t(string(), undefined, undefined)}
    , {"auth_query", emqx_schema:ref("auth_query")}
    , {"super_query", emqx_schema:ref("super_query")}
    , {"acl_query", emqx_schema:ref("acl_query")}
    ];

fields("topology") ->
    [ {"$name", emqx_schema:t(integer(), undefined, undefined)}];

fields("ssl") ->
    [ {"enable", emqx_schema:t(emqx_schema:flag(), undefined, false)}
    ] ++ emqx_schema:ssl(undefined, #{verify => verify_none});

fields("auth_query") ->
    [ {"collection", emqx_schema:t(string(), undefined, "mqtt_user")}
    , {"password_field", emqx_schema:t(string(), undefined, "password")}
    , {"password_hash", emqx_schema:t(string(), undefined, undefined)}
    , {"selector", emqx_schema:t(string(), undefined, "")}
    ];

fields("super_query") ->
    [ {"enable", emqx_schema:t(emqx_schema:flag(), undefined, false)}
    , {"collection", emqx_schema:t(string(), undefined, "mqtt_user")}
    , {"super_field", emqx_schema:t(string(), undefined, "is_superuser")}
    , {"selector", emqx_schema:t(string(), undefined, "")}
    ];

fields("acl_query") ->
    [ {"enable", emqx_schema:t(emqx_schema:flag(), undefined, false)}
    , {"collection", emqx_schema:t(string(), undefined, "mqtt_user")}
    , {"selector", emqx_schema:t(string(), undefined, "")}
    , {"selectors", emqx_schema:ref("selectors")}
    ];

fields("selectors") ->
    [ {"$id", emqx_schema:t(string(), undefined, undefined)}].

translations() -> ["emqx_auth_mongo", "mongodb"].

translation("emqx_auth_mongo") ->
    [ {"server", fun tr_server/1}
    , {"auth_query", fun tr_auth_query/1}
    , {"super_query", fun tr_super_query/1}
    , {"acl_query", fun tr_acl_query/1}
    ];

translation("mongodb") ->
    [ {"cursor_timeout", fun tr_cursor_timeout/1}].

type(type) -> type();
type(default) -> single;
type(_) -> undefined.

w_mode(type) -> w_mode();
w_mode(default) -> undef;
w_mode(_) -> undefined.

r_mode(type) -> r_mode();
r_mode(default) -> undef;
r_mode(_) -> undefined.

tr_server(Conf) ->
    H = emqx_schema:conf_get("auth.mongo.server", Conf),
    Hosts = string:tokens(H, ","),
    Type0 = emqx_schema:conf_get("auth.mongo.type", Conf),
    Pool = emqx_schema:conf_get("auth.mongo.pool", Conf),
    Login = emqx_schema:conf_get("auth.mongo.username", Conf),
    Passwd = emqx_schema:conf_get("auth.mongo.password", Conf),
    DB = emqx_schema:conf_get("auth.mongo.database", Conf),
    AuthSrc = emqx_schema:conf_get("auth.mongo.auth_source", Conf),
    R = emqx_schema:conf_get("auth.mongo.w_mode", Conf),
    W = emqx_schema:conf_get("auth.mongo.r_mode", Conf),
    Login0 = case Login =:= [] of
                 true -> [];
                 false -> [{login, list_to_binary(Login)}]
             end,
    Passwd0 = case Passwd =:= [] of
                  true -> [];
                  false -> [{password, list_to_binary(Passwd)}]
              end,
    W0 = case W =:= undef of
             true -> [];
             false -> [{w_mode, W}]
         end,
    R0 = case R =:= undef  of
             true -> [];
             false -> [{r_mode, R}]
         end,

    Ssl = case emqx_schema:tr_ssl("auth.mongo.ssl", Conf) of
              undefined -> [];
              SslOpts -> [{ssl, true}, {ssl_opts, SslOpts}]
          end,

    WorkerOptions = [{database, list_to_binary(DB)}, {auth_source, list_to_binary(AuthSrc)}]
        ++ Login0 ++ Passwd0 ++ W0 ++ R0 ++ Ssl,

    Keys = emqx_schema:keys(["auth", "mongo", "topology"], Conf),
    Options = lists:map(fun(Key) ->
        Name2 = case Key of
                    "local_threshold_ms"          -> "localThresholdMS";
                    "connect_timeout_ms"          -> "connectTimeoutMS";
                    "socket_timeout_ms"           -> "socketTimeoutMS";
                    "server_selection_timeout_ms" -> "serverSelectionTimeoutMS";
                    "wait_queue_timeout_ms"       -> "waitQueueTimeoutMS";
                    "heartbeat_frequency_ms"      -> "heartbeatFrequencyMS";
                    "min_heartbeat_frequency_ms"  -> "minHeartbeatFrequencyMS";
                    _ -> Key
                end,
        {list_to_atom(Name2), emqx_schema:conf_get(["auth.mongo.topology", Key], Conf)}
                        end, Keys),

    Type = case Type0 =:= rs of
               true -> {Type0, list_to_binary(emqx_schema:conf_get("auth.mongo.rs_set_name", Conf))};
               false -> Type0
           end,
    [{type, Type},
     {hosts, Hosts},
     {options, Options},
     {worker_options, WorkerOptions},
     {auto_reconnect, 1},
     {pool_size, Pool}].

tr_cursor_timeout(Conf) ->
    case emqx_schema:conf_get("auth.mongo.query_timeout", Conf) of
        undefined -> infinity;
        Duration ->
            case cuttlefish_duration:parse(Duration, ms) of
                {error, Reason} -> error(Reason);
                Ms when is_integer(Ms) -> Ms
            end
    end.

tr_auth_query(Conf) ->
    case emqx_schema:conf_get("auth.mongo.auth_query.collection", Conf) of
        undefined -> undefined;
        Collection ->
            PasswordField = emqx_schema:conf_get("auth.mongo.auth_query.password_field", Conf),
            PasswordHash = emqx_schema:conf_get("auth.mongo.auth_query.password_hash", Conf, ""),
            SelectorStr = emqx_schema:conf_get("auth.mongo.auth_query.selector", Conf),
            SelectorList =
                lists:map(fun(Selector) ->
                    case string:tokens(Selector, "=") of
                        [Field, Val] -> {list_to_binary(Field), list_to_binary(Val)};
                        _ -> {<<"username">>, <<"%u">>}
                    end
                          end, string:tokens(SelectorStr, ", ")),

            PasswordFields = [list_to_binary(Field) || Field <- string:tokens(PasswordField, ",")],
            HashValue =
                case string:tokens(PasswordHash, ",") of
                    [Hash]           -> list_to_atom(Hash);
                    [Prefix, Suffix] -> {list_to_atom(Prefix), list_to_atom(Suffix)};
                    [Hash, MacFun, Iterations, Dklen] -> {list_to_atom(Hash), list_to_atom(MacFun), list_to_integer(Iterations), list_to_integer(Dklen)};
                    _                -> plain
                end,
            [{collection, Collection},
             {password_field, PasswordFields},
             {password_hash, HashValue},
             {selector, SelectorList}]
    end.

tr_super_query(Conf) ->
    case emqx_schema:conf_get("auth.mongo.super_query.collection", Conf) of
        undefined -> undefined;
        Collection  ->
            SuperField = emqx_schema:conf_get("auth.mongo.super_query.super_field", Conf),
            SelectorStr = emqx_schema:conf_get("auth.mongo.super_query.selector", Conf),
            SelectorList =
                lists:map(fun(Selector) ->
                    case string:tokens(Selector, "=") of
                        [Field, Val] -> {list_to_binary(Field), list_to_binary(Val)};
                        _ -> {<<"username">>, <<"%u">>}
                    end
                          end, string:tokens(SelectorStr, ", ")),
            [{collection, Collection}, {super_field, SuperField}, {selector, SelectorList}]
    end.

tr_acl_query(Conf) ->
    case emqx_schema:conf_get("auth.mongo.acl_query.collection", Conf) of
        undefined -> undefined;
        Collection ->
            SelectorStrList =
                [emqx_schema:conf_get("auth.mongo.acl_query.selector", Conf, [])]
             ++ [emqx_schema:conf_get(["auth.mongo.acl_query.selectors", Key], Conf) ||
                    Key <- emqx_schema:keys("auth.mongo.acl_query.selectors", Conf)],
            SelectorListList =
                lists:map(
                    fun(SelectorStr) ->
                        lists:map(fun(Selector) ->
                            case string:tokens(Selector, "=") of
                                [Field, Val] -> {list_to_binary(Field), list_to_binary(Val)};
                                _ -> {<<"username">>, <<"%u">>}
                            end
                                  end, string:tokens(SelectorStr, ", "))
                    end,
                    SelectorStrList),
            [{collection, Collection}, {selector, SelectorListList}]
    end.
