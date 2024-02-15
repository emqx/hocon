-module(emqx_auth_jwt_schema).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-export([roots/0, fields/1, translations/0, translation/1, namespace/0]).

namespace() -> "auth_jwt".
roots() -> ["auth"].

fields("auth") ->
    [ {"jwt", emqx_schema:ref("jwt")}];

fields("jwt") ->
    [ {"secret", emqx_schema:t(string(), "emqx_auth_jwt.secret", undefined)}
    , {"jwks", emqx_schema:ref("jwks")}
    , {"from", emqx_schema:t(union(username, password), "emqx_auth_jwt.from", password)}
    , {"pubkey", emqx_schema:t(string(), "emqx_auth_jwt.pubkey", undefined)}
    , {"signature_format", emqx_schema:t(union(raw, der), "emqx_auth_jwt.jwerl_opts", der)}
    , {"verify_claims", emqx_schema:ref("verify_claims")}];

fields("jwks") ->
    [ {"endpoint", emqx_schema:t(string(), "emqx_auth_jwt.jwks", undefined)}
    , {"refresh_interval", emqx_schema:t(emqx_schema:duration(),
                                         "emqx_auth_jwt.refresh_interval", undefined)}];

fields("verify_claims") ->
    [ {"enable", emqx_schema:t(emqx_schema:flag(), undefined, false)}
    , {"claims", hoconsc:map("name", string())}
    ].

translations() -> ["emqx_auth_jwt"].

translation("emqx_auth_jwt") ->
    [ {"verify_claims", fun tr_verify_claims/1}].

tr_verify_claims(Conf) ->
    case emqx_schema:conf_get("auth.jwt.verify_claims.enable", Conf) of
        false -> undefined;
        true ->
            lists:foldr(
                fun(Key, Acc) ->
                    [{list_to_atom(Key), list_to_binary(emqx_schema:conf_get(Key, Conf))} | Acc]
                end, [], emqx_schema:keys("auth.jwt.verify_claims.claims", Conf))
    end.
