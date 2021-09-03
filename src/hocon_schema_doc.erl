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
-include("hocon_private.hrl").

gen(Schema) ->
    Roots = hocon_schema:roots(Schema),
    RootFields = lists:map(fun({_BinName, {RootFieldName, RootFieldSchema}}) ->
                                   {RootFieldName, RootFieldSchema}
                           end, maps:to_list(Roots)),
    All = find_structs(Schema, RootFields, #{}),
    RootNs = hocon_schema:namespace(Schema),
    RootKey = {RootNs, "Root Keys"},
    [fmt_structs(1, RootNs, [{RootKey, RootFields}]),
     fmt_structs(2, RootNs, lists:keysort(1, maps:to_list(All)))].

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

fmt_structs(_HeadWeight, _RootNs, []) -> [];
fmt_structs(HeadWeight, RootNs, [{{Ns, Name}, Fields} | Rest]) ->
    [fmt_struct(HeadWeight, RootNs, Ns, Name, Fields), "\n" |
     fmt_structs(HeadWeight, RootNs, Rest)].

fmt_struct(HeadWeight, RootNs, Ns0, Name, Fields) ->
    Ns = case RootNs =:= Ns0 of
             true -> undefined;
             false -> Ns0
         end,
    FieldMd = fmt_fields(HeadWeight + 1, Ns, Fields),
    FullNameDisplay = ref(Ns, Name),
    [hocon_md:h(HeadWeight, FullNameDisplay), FieldMd].

fmt_fields(_Weight, _Ns, []) -> [];
fmt_fields(Weight, Ns, [{Name, FieldSchema} | Fields]) ->
    Type = fmt_type(Ns, hocon_schema:field_schema(FieldSchema, type)),
    Default = fmt_default(hocon_schema:field_schema(FieldSchema, default)),
    Desc = hocon_schema:field_schema(FieldSchema, desc),
    NewMd =
        [ ["- ", bin(Name), ": ", Type, "\n"]
        , case Desc =/= undefined of
              true -> ["  - Description: ", Desc, "\n"];
              false -> []
          end
        , case Default =/= undefined of
            true  -> ["  - Default:", Default, "\n"];
            false -> []
          end
        ],
    [NewMd | fmt_fields(Weight, Ns, Fields)].

fmt_default(undefined) -> undefined;
fmt_default(Value) ->
    case hocon_pp:do(Value, #{newline => "", embedded => true}) of
        [OneLine] -> [" `", OneLine, "`"];
        Lines -> ["\n```\n", [[L, "\n"] || L <- Lines], "```"]
    end.

fmt_type(Ns, T) -> hocon_md:code(do_type(Ns, T)).

do_type(_Ns, A) when is_atom(A) -> bin(A); % singleton
do_type(Ns, Ref) when is_list(Ref) -> do_type(Ns, ?REF(Ref));
do_type(Ns, ?REF(Ref)) -> hocon_md:local_link(ref(Ns, Ref), ref(Ns, Ref));
do_type(_Ns, ?R_REF(Module, Ref)) -> do_type(hocon_schema:namespace(Module), ?REF(Ref));
do_type(Ns, ?ARRAY(T)) -> io_lib:format("[~s]", [do_type(Ns, T)]);
do_type(Ns, ?UNION(Ts)) -> lists:join(" | ", [do_type(Ns, T) || T <- Ts]);
do_type(_Ns, ?ENUM(Symbols)) -> lists:join(" | ", [bin(S) || S <- Symbols]);
do_type(Ns, ?LAZY(T)) -> do_type(Ns, T);
do_type(_Ns, {'$type_refl', #{name := Type}}) -> lists:flatten(Type).

ref(undefined, Name) -> Name;
ref(Ns, Name) ->
    %% when namespace is the same as reference name
    %% we do not prepend the reference link with namespace
    %% because the root name is already unique enough
    case bin(Ns) =:= bin(Name) of
        true -> bin(Ns);
        false -> [bin(Ns), ":", bin(Name)]
    end.

bin(S) when is_list(S) -> iolist_to_binary(S);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(B) when is_binary(B) -> B.
