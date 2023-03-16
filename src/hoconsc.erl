%%--------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-export([is_schema/1]).
-export([union_members/1]).

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
%% A union is either a list of types
%% or an anonymous function which is able to return all members
%% as well as select a member depending on the prvoided value input.
%% For example, in case all members share the same `kind' field in the struct
%% and the type of each kind depends on the field value:
%% when `kind' is `foo', it's a `ref(foo)' type.
%% we can design the selector as below.
%% 1. we need a way to retrieve all types for schema dump
%%    and document generation, so we need:
%%    `fun(all_union_members) -> [ref(foo), ref(bar)];'
%% 2. select possible type(s) depending on the `kind' field.
%%    `({value, #{<<"kind">> := <<"foo">>}) -> [ref(foo)];'
%%    `({value, #{<<"kind">> := <<"bar">>}} -> [ref(bar)].'
-spec union(hocon_schema:union_members()) -> ?UNION(hocon_schema:union_members()).
union(OfTypes) when is_list(OfTypes) orelse is_function(OfTypes, 1) -> ?UNION(OfTypes).

%% @doc make a enum type.
enum(OfSymbols) when is_list(OfSymbols) -> ?ENUM(OfSymbols).

%% @doc make a lazy type.
lazy(HintType) -> ?LAZY(HintType).

%% @doc make a map type.
map(Name, Type) -> ?MAP(Name, Type).

%% @doc Check Type is a hocon type.
is_schema(?UNION(Members)) -> lists:all(fun is_schema/1, union_members(Members));
is_schema(?ARRAY(ElemT)) -> is_schema(ElemT);
is_schema(?LAZY(HintT)) -> is_schema(HintT);
is_schema(?REF(_)) -> true;
is_schema(?R_REF(_, _)) -> true;
is_schema(?ENUM(_)) -> true;
is_schema(?MAP(_, _)) -> true;
is_schema(#{type := _}) -> true;
is_schema(Type) when ?IS_TYPEREFL(Type) -> true;
is_schema(Func) when is_function(Func) -> true;
is_schema(_) -> false.

assert_type(S) when is_function(S) -> error({expecting_type_but_got_schema, S});
assert_type(#{type := _} = S) ->
    error({expecting_type_but_got_schema, S});
assert_type(?UNION(Members)) ->
    lists:foreach(fun assert_type/1, union_members(Members));
assert_type(?ENUM(Symbols)) ->
    lists:foreach(
        fun(S) ->
            case is_atom(S) orelse is_integer(S) of
                true -> ok;
                false -> error({bad_enum_type, S})
            end
        end,
        Symbols
    );
assert_type(?ARRAY(ElemT)) ->
    assert_type(ElemT);
assert_type(?LAZY(HintT)) ->
    assert_type(HintT);
assert_type(_) ->
    ok.

union_members(Members) when is_list(Members) ->
    Members;
union_members(Members) when is_function(Members, 1) ->
    union_members(Members(all_union_members)).
