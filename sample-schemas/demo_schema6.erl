-module(demo_schema6).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-export([namespace/0, roots/0, fields/1, desc/1]).

namespace() -> undefined.

roots() ->
    [ {foo, hoconsc:array(hoconsc:ref(foo))}
    ].

fields(foo) ->
    [ {int, integer()}
    , {hidden_field, hoconsc:mk(hoconsc:ref(?MODULE, im_hidden), #{importance => hidden})}
    ];
fields(im_hidden) ->
    [{i_should_be_hidden, integer()}].

desc(foo) ->
    {foo, invalid};
desc(_) ->
    undefined.
