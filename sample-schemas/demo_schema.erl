-module(demo_schema).

-include_lib("typerefl/include/types.hrl").

-type ipv4_address() :: {byte(), byte(), byte(), byte()}.
-typerefl_from_string({ipv4_address/0, inet, parse_ipv4_address}).

-type birthdays() :: [#{m := 1..12, d := 1..31}].

-reflect_type([ipv4_address/0, birthdays/0]).

-export([namespaces/0, fields/1]).

namespaces() -> ["foo", "a.b", "x.y"].

fields("foo") ->
    [ {"setting", fun setting/1}
    , {"endpoint", fun endpoint/1}
    , {"greet", fun greet/1}
    , {"numbers", fun numbers/1}
    , {"ref_x_y", fun ref_x_y/1}
    ];

fields("a.b") ->
    [ {"birthdays", fun birthdays/1}
    , {"some_int", fun int/1}
    ];

fields("x.y") ->
    [ {"some_int", fun int/1}
    ].

setting(mapping) -> "app_foo.setting";
setting(type) -> string();
setting(override_env) -> "MY_OVERRIDE";
setting(_) -> undefined.

endpoint(mapping) -> "app_foo.endpoint";
endpoint(type) -> ipv4_address();
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

ref_x_y(mapping) -> undefined;
ref_x_y(type) -> {ref, fields("x.y")};
ref_x_y(_) -> undefined.
