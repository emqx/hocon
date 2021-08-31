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

-export([gen/1]).

-include("hoconsc.hrl").

gen(Schema) ->
    Roots = hocon_schema:roots(Schema),
    RootFields = lists:map(fun({_BinName, {RootFieldName, RootFieldSchema}}) ->
                                   {RootFieldName, RootFieldSchema}
                           end, maps:to_list(Roots)),
    All = find_structs(Schema, RootFields, #{}),
    RootNs = hocon_schema:namespace(Schema),
    RootKey = {RootNs, "Root Keys"},
    fmt_structs(RootNs, [{RootKey, RootFields} | lists:keysort(1, maps:to_list(All))]).

find_structs(_Schema, [], Acc) -> Acc;
find_structs(Schema, [{_FieldName, FieldSchema} | Fields], Acc0) ->
    Type = hocon_schema:field_schema(FieldSchema, type),
    Acc = find_structs_per_type(Schema, Type, Acc0),
    find_structs(Schema, Fields, Acc).

find_structs_per_type(Schema, Name, Acc) when is_list(Name) ->
    find_ref(Schema, Name, Acc);
find_structs_per_type(Schema, ?REF(Name), Acc) ->
    find_ref(Schema, Name, Acc);
find_structs_per_type(_Schema, ?R_REF(Module, Name), Acc) ->
    find_ref(Module, Name, Acc);
find_structs_per_type(Schema, ?LAZY(Type), Acc) ->
    find_structs_per_type(Schema, Type, Acc);
find_structs_per_type(Schema, ?ARRAY(Type), Acc) ->
    find_structs_per_type(Schema, Type, Acc);
find_structs_per_type(Schema, ?UNION(Types), Acc) ->
    lists:foldl(fun(T, AccIn) ->
                        find_structs_per_type(Schema, T, AccIn)
                end, Acc, Types);
find_structs_per_type(_Schema, _Type, Acc) ->
    Acc.

find_ref(Schema, Name, Acc) ->
    Namespace = hocon_schema:namespace(Schema),
    Key = {Namespace, Name},
    case maps:find(Key, Acc) of
        {ok, _} ->
            %% visted before, avoid duplication
            Acc;
        error ->
            Fields = hocon_schema:fields(Schema, Name),
            find_structs(Schema, Fields, Acc#{Key => Fields})
    end.

fmt_structs(_RootNs, []) -> [];
fmt_structs(RootNs, [{{Ns, Name}, Fields} | Rest]) ->
    [fmt_struct(RootNs, Ns, Name, Fields) | fmt_structs(RootNs, Rest)].

fmt_struct(RootNs, Ns0, Name, Fields) ->
    Th = ["name", "type", "default"],
    {HeaderSize, Ns} = case RootNs =:= Ns0 of
                           true -> {1, undefined};
                           false -> {2, Ns0}
                       end,
    FieldMd = fmt_fields(Ns, Fields, []),
    FullNameDisplay = ref(Ns, Name),
    [hocon_md:h(HeaderSize, FullNameDisplay), hocon_md:th(Th) , FieldMd].

fmt_fields(_Ns, [], Md) ->
    lists:reverse(Md);
fmt_fields(Ns, [{Name, FieldSchema} | Fields], Md) ->
    Default = fmt_default(hocon_schema:field_schema(FieldSchema, default)),
    Type = fmt_type(Ns, hocon_schema:field_schema(FieldSchema, type)),
    fmt_fields(Ns, Fields, [hocon_md:td([bin(Name), Type, Default]) | Md]).

fmt_default(undefined) -> "";
fmt_default(Value) -> hocon_md:code(io_lib:format("~100000p", [Value])).

fmt_type(Ns, T) -> hocon_md:code(do_type(Ns, T)).

do_type(_Ns, A) when is_atom(A) -> bin(A); % singleton
do_type(Ns, Ref) when is_list(Ref) -> do_type(Ns, ?REF(Ref));
do_type(Ns, ?REF(Ref)) -> hocon_md:local_link(ref(Ns, Ref), ref(Ns, Ref));
do_type(_Ns, ?R_REF(Module, Ref)) -> do_type(hocon_schema:namespace(Module), ?REF(Ref));
do_type(Ns, ?ARRAY(T)) -> hocon_md:code(io_lib:format("[~s]", [do_type(Ns, T)]));
do_type(Ns, ?UNION(Ts)) -> hocon_md:code(lists:join(" | ", [do_type(Ns, T) || T <- Ts]));
do_type(_Ns, ?ENUM(Symbols)) -> hocon_md:code(lists:join(" | ", [bin(S) || S <- Symbols]));
do_type(Ns, ?LAZY(T)) -> do_type(Ns, T);
do_type(_Ns, {'$type_refl', #{name := Type}}) -> hocon_md:code(lists:flatten(Type)).

ref(undefined, Name) -> Name;
ref(Ns, Name) -> [bin(Ns), ":", bin(Name)].

bin(S) when is_list(S) -> iolist_to_binary(S);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(B) when is_binary(B) -> B.
