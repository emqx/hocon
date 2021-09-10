%%%-------------------------------------------------------------------
%% @doc example public API
%% @end
%%%-------------------------------------------------------------------

-module(example_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    example_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
