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

%% this module exports APIs to help composing hocon field schema.
-module(hoconsc).

-export([t/1, t/2]).
-export([ref/1, ref/2]).
-export([array/1, union/1, enum/1]).
-export([lazy/1]).

-include("hoconsc.hrl").

t(Type) -> #{type => Type}.

t(Type, Opts) ->
    Opts#{type => Type}.

%% @doc Make a local reference type to local schema's struct definition.
ref(Name) -> {ref, Name}.

%% @doc Make a 'remote' reference type to a struct defined
%% in the given module's `fields/1` callback.
ref(Module, Name) -> {ref, Module, Name}.

%% @doc make an array type
array(OfType) -> ?ARRAY(OfType).

%% @doc make a union type.
union(OfTypes) when is_list(OfTypes) -> ?UNION(OfTypes).

%% @doc make a enum type.
enum(OfSymbols) when is_list(OfSymbols) -> ?ENUM(OfSymbols).

lazy(HintType) -> ?LAZY(HintType).
