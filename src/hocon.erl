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

-module(hocon).

-export([ load/1
        , parse/1
        ]).

load(File) ->
    {ok, S} = file:read_file(File),
    parse(S).

parse(S) ->
    {ok, Tokens, _} = hocon_lexer:string(S),
    io:format("Tokens: ~p~n", [Tokens]),
    {ok, Result} = hocon_parser:parse(Tokens),
    io:format("Result: ~p~n", [Result]),
    Result.

