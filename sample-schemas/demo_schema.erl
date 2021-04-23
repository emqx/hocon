-module(demo_schema).

-include_lib("typerefl/include/types.hrl").

-type ip() :: ipv4() | ipv6().
-type ipv4() :: {0..255, 0..255, 0..255, 0..255}.
-type ipv6() :: {0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535}.

-reflect_type([ip/0]).

-export([fields/0]).

fields() ->
    [ {"foo.setting", fun setting/1}
    , {"foo.endpoint", fun endpoint/1}
    , {"foo.greet", fun greet/1}
    , {"foo.numbers", fun numbers/1}
    ].

setting(mapping) -> "app_foo.setting";
setting(type) -> string();
setting(converter) -> fun to_string/1;
setting(override_env) -> "MY_OVERRIDE";
setting(_) -> undefined.

endpoint(mapping) -> "app_foo.endpoint";
endpoint(type) -> ip();
endpoint(converter) -> fun to_ip/1;
endpoint(_) -> undefined.

greet(mapping) -> "app_foo.greet";
greet(type) -> binary();
greet(validator) ->
    fun (Value) ->
        case Value =:= "hello" of
            true ->
                ok;
            false ->
                {error, greet}
        end
    end;
greet(_) -> undefined.

numbers(mapping) -> "app_foo.numbers";
numbers(type) -> list(integer());
numbers(_) -> undefined.

to_ip(Bin) when is_binary(Bin) ->
    to_ip(binary_to_list(Bin));
to_ip(Str) when is_list(Str) ->
    case inet:parse_address(Str) of
        {ok, Addr} ->
            Addr;
        {error, einval} ->
            Str
    end;
to_ip(V) -> V.

to_string(Int) when is_integer(Int) ->
    integer_to_list(Int);
to_string(Bin) when is_binary(Bin) ->
    binary_to_list(Bin);
to_string(V) -> V.
