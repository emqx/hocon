-module(demo_schema2).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-export([structs/0, fields/1]).

structs() -> [{array, foo}].

fields(foo) ->
    [ {int, integer()}
    ].
