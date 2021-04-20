-module(demo_schema).

-export([foo__setting/1, foo__endpoint/1]).

foo__setting(map_to) -> "app_foo.setting";
foo__setting(type) -> string;
foo__setting(validators) -> fun(X) -> length(X) < 10 end;
foo__setting(_) -> undefined.

foo__endpoint(map_to) -> "app_foo.endpoint";
foo__endpoint(type) -> ip;
foo__endpoint(_) -> undefined.
