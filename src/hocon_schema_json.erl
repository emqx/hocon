%%--------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon_schema_json).

-export([gen/1]).

-include("hoconsc.hrl").
-include("hocon_private.hrl").

%% @doc Generate a JSON compatible list of `map()'s.
-spec gen(hocon_schema:schema()) -> [map()].
gen(Schema) ->
    {RootNs, RootFields, Structs} = hocon_schema:find_structs(Schema),
    [ gen_struct(RootNs, RootNs, "Root Config Keys", #{fields => RootFields})
    | lists:map(fun({Ns, Name, Fields}) -> gen_struct(RootNs, Ns, Name, Fields) end, Structs)
    ].

gen_struct(RootNs, Ns0, Name, #{fields := Fields} = Meta) ->
    Ns = case RootNs =:= Ns0 of
             true -> undefined;
             false -> Ns0
         end,
    Paths = case Meta of
                #{paths := Ps} -> lists:sort(maps:keys(Ps));
                _ -> []
            end,
    FullNameDisplay = fmt_ref(Ns, Name),
    S0 = #{ full_name => bin(FullNameDisplay)
          , paths => [bin(P) || P <- Paths]
          , fields => fmt_fields(Ns, Fields)
          },
    case Meta of
        #{desc := StructDoc} -> S0#{desc => bin(StructDoc)};
        _ -> S0
    end.

fmt_fields(_Ns, []) -> [];
fmt_fields(Ns, [{Name, FieldSchema} | Fields]) ->
    case hocon_schema:field_schema(FieldSchema, hidden) of
        true -> fmt_fields(Ns, Fields);
        _ -> [fmt_field(Ns, Name, FieldSchema) | fmt_fields(Ns, Fields)]
    end.

fmt_field(Ns, Name, FieldSchema) ->
    L = [ {name, bin(Name)}
        , {type, fmt_type(Ns, hocon_schema:field_schema(FieldSchema, type))}
        , {default, fmt_default(hocon_schema:field_schema(FieldSchema, default))}
        , {desc, bin(hocon_schema:field_schema(FieldSchema, desc))}
        , {extra, hocon_schema:field_schema(FieldSchema, extra)}
        ],
    maps:from_list([{K, V} || {K, V} <- L, V =/= undefined]).

fmt_default(undefined) -> undefined;
fmt_default(Value) ->
    case hocon_pp:do(Value, #{newline => "", embedded => true}) of
        [OneLine] -> #{oneliner => true, hocon => bin(OneLine)};
        Lines -> #{oneliner => false, hocon => bin([[L, "\n"] || L <- Lines])}
    end.

fmt_type(_Ns, A) when is_atom(A) ->
    #{ kind => singleton
     , name => bin(A)
     };
fmt_type(Ns, Ref) when is_list(Ref) ->
    fmt_type(Ns, ?REF(Ref));
fmt_type(Ns, ?REF(Ref)) ->
    #{ kind => struct
     , name => bin(fmt_ref(Ns, Ref))
     };
fmt_type(_Ns, ?R_REF(Module, Ref)) ->
    fmt_type(hocon_schema:namespace(Module), ?REF(Ref));
fmt_type(Ns, ?ARRAY(T)) ->
    #{ kind => array
     , elements => fmt_type(Ns, T)
     };
fmt_type(Ns, ?UNION(Ts)) ->
    #{ kind => union
     , members => [fmt_type(Ns, T) || T <- Ts]
     };
fmt_type(_Ns, ?ENUM(Symbols)) ->
    #{ kind => enum
     , symbols => [bin(S) || S <- Symbols]
     };
fmt_type(Ns, ?LAZY(T)) ->
    fmt_type(Ns, T);
fmt_type(Ns, ?MAP(Name, T)) ->
    #{ kind => map
     , name => bin(Name)
     , values => fmt_type(Ns, T)
     };
fmt_type(_Ns, {'$type_refl', #{name := Type}}) ->
    #{kind => primitive,
      name => bin(lists:flatten(Type))
     }.

fmt_ref(undefined, Name) -> Name;
fmt_ref(Ns, Name) ->
    %% when namespace is the same as reference name
    %% we do not prepend the reference link with namespace
    %% because the root name is already unique enough
    case bin(Ns) =:= bin(Name) of
        true -> bin(Ns);
        false -> [bin(Ns), ":", bin(Name)]
    end.

bin(undefined) -> undefined;
bin(S) when is_list(S) -> unicode:characters_to_binary(S, utf8);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(B) when is_binary(B) -> B.
