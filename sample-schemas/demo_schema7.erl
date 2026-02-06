-module(demo_schema7).

-include_lib("typerefl/include/types.hrl").

-behaviour(hocon_schema).

-export([namespace/0, roots/0, fields/1, desc/1, root_converter/1]).

namespace() -> undefined.

roots() ->
    [ {foo, hoconsc:map(name, hoconsc:ref(bar))}
    ].

fields(bar) ->
    [ {int, hoconsc:mk(integer(), #{})}
    , {baz, hoconsc:mk(binary(), #{})}
    , {quux, hoconsc:mk(hoconsc:ref(quux), #{})}
    ];
fields(quux) ->
    [ {int, hoconsc:mk(integer(), #{})}
    ].

desc(bar) ->
    {bar, invalid};
desc(_) ->
    undefined.

root_converter(bar) ->
    fun bar_root_converter/2;
root_converter(_) ->
    undefined.

bar_root_converter(#{<<"int">> := N} = Conf0, _HoconOpts) ->
    Conf0#{<<"int">> := N + 10};
bar_root_converter(Conf0, _HoconOpts) ->
    Conf0.
