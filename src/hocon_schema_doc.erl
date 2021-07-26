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

-module(hocon_schema_doc).

-export([doc/2]).

doc(Module, Output) ->
    Result = structs(Module, hocon_schema:structs(Module)),
    file:write_file(Output, lists:flatten(Result)).

structs(Module, Structs) ->
    StructsWithLinks = [hocon_md:local_link(S, S) || S <- Structs],
    RefStructs = rm_dup(all_structs(Module, Structs, lists:reverse(Structs)) -- Structs),
    StructsMd = struct(Module, Structs, []),
    RefStructsMd = struct(Module, RefStructs, []),
    hocon_md:h(2, "Structs") ++ hocon_md:ul(StructsWithLinks) ++ StructsMd ++ RefStructsMd.

struct(_Module, [], Md) ->
    lists:reverse(Md);
struct(Module, [S | Structs], Md) ->
    Fields = hocon_schema:fields(Module, S),
    Th = ["name", "type", "default"],
    FieldMd = field(Module, Fields, []),
    struct(Module, Structs, [hocon_md:h(3, S) ++ hocon_md:th(Th) ++ FieldMd | Md]).

field(_Module, [], Md) ->
    lists:reverse(Md);
field(Module, [{Name, FieldSchema} | Fields], Md) ->
    Default = default(hocon_schema:field_schema(FieldSchema, default)),
    Type = type(hocon_schema:field_schema(FieldSchema, type)),
    field(Module, Fields, [hocon_md:td([field_name(Name), Type, Default]) | Md]).

default(undefined) -> "";
default(Value) -> io_lib:format("~p", [Value]).

type(T) -> hocon_md:code(do_type(T)).

do_type(A) when is_atom(A) -> A;
do_type(Ref) when is_list(Ref) -> do_type({ref, Ref});
do_type({ref, Ref}) -> io_lib:format("[~s](#~s)", [Ref, Ref]);
do_type({'$type_refl', #{name := Type}}) -> lists:flatten(Type);
do_type({array, T}) -> io_lib:format("array[~s]", [do_type(T)]);
do_type({union, Ts}) -> io_lib:format("union[~s]", [lists:join(", ", [do_type(T) || T <- Ts])]).

all_structs(_Module, [], Acc) ->
    lists:reverse(Acc);
all_structs(Module, [S | Structs], Acc) ->
    Fields = hocon_schema:fields(Module, S),
    all_structs(Module, Structs, do_all_structs(Module, Fields, []) ++ Acc).

do_all_structs(_Module, [], Acc) ->
    lists:reverse(Acc);
do_all_structs(Module, [{_Name, FieldSchema} | Fields], Acc) ->
    Refs = get_refs(hocon_schema:field_schema(FieldSchema, type)),
    do_all_structs(Module, Fields, all_structs(Module, Refs, []) ++ Refs ++ Acc).

get_refs({T, R}) when T =:= array; T =:= union ->
    get_refs(R);
get_refs([R | _] = Refs) when is_list(R) ->
    Refs;
get_refs({ref, R}) ->
    get_refs(R);
get_refs(R) when is_list(R) ->
    [R];
get_refs(_) ->
    [].

rm_dup([])    -> [];
rm_dup([H | T]) -> [H | [X || X <- rm_dup(T), X /= H]].

field_name(A) when is_atom(A) ->
    atom_to_list(A);
field_name(S) when is_list(S) ->
    S.


