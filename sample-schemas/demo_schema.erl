-module(demo_schema).

-include_lib("typerefl/include/types.hrl").

-type birthdays() :: [map()].
-behaviour(hocon_schema).

-reflect_type([birthdays/0]).

-export([structs/0, fields/1, translations/0, translation/1]).

structs() -> [foo, "a.b"].
translations() -> ["app_foo"].

fields(foo) ->
    [ {setting, fun setting/1}
    , {endpoint, fun endpoint/1}
    , {greet, fun greet/1}
    , {numbers, fun numbers/1}
    , {ref_x_y, fun ref_x_y/1}
    , {ref_j_k, fun ref_j_k/1}
    , {min, fun priv_int/1}
    , {max, fun priv_int/1}
    ];

fields("a.b") ->
    [ {"birthdays", fun birthdays/1}
    , {"some_int", fun int/1}
    ];

fields("x.y") ->
    [ {"some_int", fun priv_int/1}
    ];

fields("j.k") ->
    [ {"some_int", fun priv_int/1}
    ].


translation("app_foo") ->
    [ {"range", fun range/1} ].

setting(mapping) -> "app_foo.setting";
setting(type) -> string();
setting(override_env) -> "MY_OVERRIDE";
setting(_) -> undefined.

range(Conf) ->
    Min = hocon_schema:deep_get("foo.min", Conf, value),
    Max = hocon_schema:deep_get("foo.max", Conf, value),
    case Min < Max of
        true ->
            {Min, Max};
        _ ->
            throw("should be min < max")
    end,
    {Min, Max}.

endpoint(mapping) -> "app_foo.endpoint";
endpoint(type) -> typerefl:ip4_address();
endpoint(_) -> undefined.

greet(mapping) -> "app_foo.greet";
greet(type) -> typerefl:regexp_string("^hello$");
greet(_) -> undefined.

numbers(mapping) -> "app_foo.numbers";
numbers(type) -> list(integer());
numbers(_) -> undefined.

birthdays(mapping) -> "a.b.birthdays";
birthdays(type) -> birthdays();
birthdays(_) -> undefined.

int(mapping) -> "a.b.some_int";
int(type) -> integer();
int(_) -> undefined.

priv_int(type) -> integer();
priv_int(_) -> undefined.

ref_x_y(mapping) -> undefined;
ref_x_y(type) -> {ref, fields("x.y")};
ref_x_y(_) -> undefined.

ref_j_k(mapping) -> "app_foo.refjk";
ref_j_k(type) -> {ref, fields("j.k")};
ref_j_k(_) -> undefined.
