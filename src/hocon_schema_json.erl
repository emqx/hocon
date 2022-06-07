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

-export([gen/1, gen/2]).

-include("hoconsc.hrl").
-include("hocon_private.hrl").

-type fmtfieldfunc() :: fun(
    (
        Namespace :: binary() | undefined,
        Name :: hocon_schema:name(),
        hocon_schema:field_schema(),
        Options :: map()
    ) -> map()
).

%% @doc Generate a JSON compatible list of `map()'s.
-spec gen(hocon_schema:schema()) -> [map()].
gen(Schema) ->
    Opts = #{formatter => fun fmt_field/4, desc_file => undefined, lang => "en"},
    gen(Schema, Opts).
%% @doc Generate a JSON compatible list of `map()'s.
-spec gen(
    hocon_schema:schema(),
    #{formatter => fmtfieldfunc(), lang => string(), desc_file => filename:file() | undefined}
) ->
    [map()].
gen(Schema, Opts) ->
    {RootNs, RootFields, Structs} = hocon_schema:find_structs(Schema),
    {File, Opts1} = maps:take(desc_file, Opts),
    Cache = hocon_schema:new_desc_cache(File),
    Opts2 = Opts1#{cache => Cache},
    Json =
        [
            gen_struct(RootNs, RootNs, "Root Config Keys", #{fields => RootFields}, Opts2)
            | lists:map(
                fun({Ns, Name, Fields}) ->
                    gen_struct(RootNs, Ns, Name, Fields, Opts2)
                end,
                Structs
            )
        ],
    hocon_schema:delete_desc_cache(Cache),
    Json.

gen_struct(_RootNs, Ns, Name, #{fields := Fields} = Meta, Opts) ->
    Paths =
        case Meta of
            #{paths := Ps} -> lists:sort(maps:keys(Ps));
            _ -> []
        end,
    S0 = #{
        full_name => bin(fmt_ref(Ns, Name)),
        paths => [bin(P) || P <- Paths],
        fields => fmt_fields(Ns, Fields, Opts)
    },
    case Meta of
        #{desc := StructDoc} -> S0#{desc => fmt_desc(StructDoc, Opts)};
        _ -> S0
    end.

fmt_fields(_Ns, [], _Opts) ->
    [];
fmt_fields(Ns, [{Name, FieldSchema} | Fields], Opts) ->
    case hocon_schema:field_schema(FieldSchema, hidden) of
        true ->
            fmt_fields(Ns, Fields, Opts);
        _ ->
            FmtFieldFun = formatter_func(Opts),
            Opts1 = Opts#{lang => maps:get(lang, Opts, "en")},
            [FmtFieldFun(Ns, Name, FieldSchema, Opts1) | fmt_fields(Ns, Fields, Opts)]
    end.

fmt_field(Ns, Name, FieldSchema, Opts) ->
    L = [
        {name, bin(Name)},
        {type, fmt_type(Ns, hocon_schema:field_schema(FieldSchema, type))},
        {default, fmt_default(hocon_schema:field_schema(FieldSchema, default))},
        {examples, hocon_schema:field_schema(FieldSchema, examples)},
        {desc, fmt_desc(hocon_schema:field_schema(FieldSchema, desc), Opts)},
        {extra, hocon_schema:field_schema(FieldSchema, extra)},
        {mapping, bin(hocon_schema:field_schema(FieldSchema, mapping))}
    ],
    maps:from_list([{K, V} || {K, V} <- L, V =/= undefined]).

fmt_default(undefined) ->
    undefined;
fmt_default(Value) ->
    case hocon_pp:do(Value, #{newline => "", embedded => true}) of
        [OneLine] -> #{oneliner => true, hocon => bin(OneLine)};
        Lines -> #{oneliner => false, hocon => bin([[L, "\n"] || L <- Lines])}
    end.

fmt_type(_Ns, A) when is_atom(A) ->
    #{
        kind => singleton,
        name => bin(A)
    };
fmt_type(Ns, Ref) when is_list(Ref) ->
    fmt_type(Ns, ?REF(Ref));
fmt_type(Ns, ?REF(Ref)) ->
    #{
        kind => struct,
        name => bin(fmt_ref(Ns, Ref))
    };
fmt_type(_Ns, ?R_REF(Module, Ref)) ->
    fmt_type(hocon_schema:namespace(Module), ?REF(Ref));
fmt_type(Ns, ?ARRAY(T)) ->
    #{
        kind => array,
        elements => fmt_type(Ns, T)
    };
fmt_type(Ns, ?UNION(Ts)) ->
    #{
        kind => union,
        members => [fmt_type(Ns, T) || T <- Ts]
    };
fmt_type(_Ns, ?ENUM(Symbols)) ->
    #{
        kind => enum,
        symbols => [bin(S) || S <- Symbols]
    };
fmt_type(Ns, ?LAZY(T)) ->
    fmt_type(Ns, T);
fmt_type(Ns, ?MAP(Name, T)) ->
    #{
        kind => map,
        name => bin(Name),
        values => fmt_type(Ns, T)
    };
fmt_type(_Ns, Type) when ?IS_TYPEREFL(Type) ->
    #{
        kind => primitive,
        name => bin(typerefl:name(Type))
    }.

fmt_ref(undefined, Name) ->
    Name;
fmt_ref(Ns, Name) ->
    %% when namespace is the same as reference name
    %% we do not prepend the reference link with namespace
    %% because the root name is already unique enough
    case bin(Ns) =:= bin(Name) of
        true -> Ns;
        false -> <<(bin(Ns))/binary, ":", (bin(Name))/binary>>
    end.

fmt_desc(Struct, Opts = #{cache := Cache}) ->
    Desc = hocon_schema:resolve_schema(Struct, Cache),
    case is_map(Desc) of
        true ->
            Lang = maps:get(lang, Opts, "en"),
            bin(hocon_maps:get(["desc", Lang], Desc));
        false ->
            bin(Desc)
    end.

bin(undefined) -> undefined;
bin(S) when is_list(S) -> unicode:characters_to_binary(S, utf8);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(B) when is_binary(B) -> B.

formatter_func(Opts) ->
    maps:get(formatter, Opts, fun fmt_field/4).
