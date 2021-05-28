-module(demo_schema).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-type duration() :: integer().

-typerefl_from_string({duration/0, emqx_schema, to_duration}).

-reflect_type([duration/0]).

-export([structs/0, fields/1, translations/0, translation/1]).

-define(FIELD(NAME, TYPE), fun(mapping) -> NAME; (type) -> TYPE; (_) -> undefined end).

structs() -> [foo, "a.b", person, "id"].
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
    [ {"some_int", fun int/1}
    ];

fields("priv.bool") ->
    [ {"val", fun priv_bool/1}
    ];

fields("priv.int") ->
    [ {"val", fun priv_int/1}
    ];

fields("x.y") ->
    [ {"some_int", fun priv_int/1}
    , {"some_dur", fun priv_duration/1}
    ];

fields("j.k") ->
    [ {"some_int", fun priv_int/1}
    ];

fields(person) ->
    [{id, ?FIELD("person.id", "id")}];

fields("id") ->
    [?FIELD("id", integer())].

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
    end.

endpoint(mapping) -> "app_foo.endpoint";
endpoint(type) -> typerefl:ip4_address();
endpoint(_) -> undefined.

greet(mapping) -> "app_foo.greet";
greet(type) -> typerefl:regexp_string("^hello$");
greet(_) -> undefined.

numbers(mapping) -> "app_foo.numbers";
numbers(type) -> list(integer());
numbers(_) -> undefined.


int(mapping) -> "a.b.some_int";
int(type) -> integer();
int(_) -> undefined.

priv_int(type) -> integer();
priv_int(_) -> undefined.

priv_duration(type) -> duration();
priv_duration(_) -> undefined.

priv_bool(type) -> boolean();
priv_bool(_) -> undefined.

ref_x_y(mapping) -> undefined;
ref_x_y(type) -> "x.y";
ref_x_y(_) -> undefined.

ref_j_k(mapping) -> "app_foo.refjk";
ref_j_k(type) -> "j.k";
ref_j_k(_) -> undefined.
