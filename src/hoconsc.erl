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

-export([mk/1, mk/2]).
-export([ref/1, ref/2]).
-export([array/1, union/1, enum/1]).
-export([lazy/1, map/2]).
-export([is_type/1]).

-include("hoconsc.hrl").

%% @doc Make a schema without metadata.
mk(Type) ->
    mk(Type, #{}).

%% @doc Make a schema with metadata.
mk(Type, Meta) ->
    assert_type(Type),
    Meta#{type => Type}.

ref(Name) -> ?REF(Name).

%% @doc Make a 'remote' reference type to a struct defined
%% in the given module's `fields/1` callback.
ref(Module, Name) -> ?R_REF(Module, Name).

%% @doc make an array type
array(OfType) -> ?ARRAY(OfType).

%% @doc make a union type.
union(OfTypes) when is_list(OfTypes) -> ?UNION(OfTypes).

%% @doc make a enum type.
enum(OfSymbols) when is_list(OfSymbols) -> ?ENUM(OfSymbols).

%% @doc make a lazy type.
lazy(HintType) -> ?LAZY(HintType).

%% @doc make a map type.
map(Name, Type) -> ?MAP(Name, Type).

%% @doc Check Type is a hocon type.
is_type(?UNION(Members)) -> lists:all(fun is_type/1, Members);
is_type(?ARRAY(ElemT)) -> is_type(ElemT);
is_type(?LAZY(HintT)) -> is_type(HintT);
is_type(?REF(_)) -> true;
is_type(?R_REF(_, _)) -> true;
is_type(#{type := _}) -> true;
is_type(Type) when ?IS_TYPEREFL(Type) -> true;
is_type(_) -> false.

assert_type(S) when is_function(S) -> error({expecting_type_but_got_schema, S});
assert_type(#{type := _} = S) -> error({expecting_type_but_got_schema, S});
assert_type(?UNION(Members)) -> lists:foreach(fun assert_type/1, Members);
assert_type(?ARRAY(ElemT)) -> assert_type(ElemT);
assert_type(?LAZY(HintT)) -> assert_type(HintT);
assert_type(_) -> ok.
