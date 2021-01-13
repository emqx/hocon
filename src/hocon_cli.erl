%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(hocon_cli).

-export([main/1]).

spec() ->
    [ {help, $h, "help", undefined, "Usage"}
    , {file, $f, "file", string, "File to load"}
    ].

main(Args) ->
    case getopt:parse(spec(), Args)  of
        {ok, {Opts, _Extra}} -> do(to_map(Opts));
        {error, Reason} -> exit(Reason)
    end.

to_map(Opts) ->
    to_map(Opts, #{}).

to_map([], Acc) -> Acc;
to_map([A | T], Acc) when is_atom(A) ->
    to_map(T, Acc#{A => true});
to_map([{K, V} | T], Acc) ->
    to_map(T, Acc#{K => V}).

do(#{help := _}) ->
    getopt:usage(spec(), "hocon", "");
do(#{file := File}) ->
    case hocon:load(File) of
        {ok, Config} -> ok = pp_eterm(Config);
        {error, Reason} -> exit(Reason)
    end.

print(IoData) -> io:put_chars(IoData).

pp_eterm(Term) ->
    print(pp_fmt_eterm(Term)).

pp_fmt_eterm(Term) ->
    io_lib:format("~p.~n", [Term]).

