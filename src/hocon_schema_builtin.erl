%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon_schema_builtin).

-include_lib("typerefl/include/types.hrl").
-include_lib("typerefl/src/typerefl_int.hrl").

-include("hoconsc.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([convert/2]).

convert(Symbol, ?ENUM(_Synbos)) ->
    case is_binary(Symbol) of
        true ->
            try binary_to_existing_atom(Symbol, utf8)
            catch _ : _ -> Symbol
            end;
        false ->
            Symbol
    end;
convert(Int, Type) when is_integer(Int) ->
    case Type =:= string() of
        true ->
            integer_to_list(Int);
        false ->
            Int
    end;
convert(Bin, Type) when is_binary(Bin) ->
    Str = binary_to_list(Bin),
    case typerefl:from_string(Type, Str) of
        {ok, V} ->
            V;
        {error, _} ->
            Str
    end;
convert(Str, Type) when is_list(Str) ->
    case typerefl:from_string(Type, Str) of
        {ok, V} ->
            V;
        {error, _} ->
            Str
    end;
convert(Other, _Type) ->
    Other.
