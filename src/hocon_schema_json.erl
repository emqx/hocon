%%--------------------------------------------------------------------
%% Copyright (c) 2022-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-export([gen/1, gen/2, dummy_desc_resolver/1]).

-include("hocon_types.hrl").

-type fmtfieldfunc() :: fun(
    (
        Namespace :: binary() | undefined,
        Name :: hocon_schema:name(),
        hocon_schema:field_schema(),
        Options :: map()
    ) -> map()
).

-type desc_resolver() :: fun((term()) -> iodata()).

%% @doc Generate a JSON compatible list of `map()'s.
-spec gen(hocon_schema:schema()) -> [map()].
gen(Schema) ->
    Opts = #{
        formatter => fun fmt_field/4,
        desc_resolver => fun dummy_desc_resolver/1
    },
    gen(Schema, Opts).

%% @doc Generate a JSON compatible list of `map()'s.
-spec gen(
    hocon_schema:schema(),
    #{
        formatter => fmtfieldfunc(),
        desc_resolver => desc_resolver(),
        include_importance_up_from => hocon_schema:importance(),
        _ => _
    }
) ->
    [map()].
gen(Schema, Opts) ->
    {RootNs, RootFields, Structs} = hocon_schema:find_structs(Schema, Opts),
    Json =
        [
            gen_struct(RootNs, "Root Config Keys", #{fields => RootFields}, Opts)
            | lists:map(
                fun({Ns, Name, Meta}) ->
                    case gen_struct(Ns, Name, Meta, Opts) of
                        #{fields := []} = Meta1 ->
                            error(
                                {struct_with_no_fields, #{
                                    namespace => Ns,
                                    name => Name,
                                    meta => Meta1,
                                    msg =>
                                        "If all children are hidden fields,"
                                        " please set the parent field as hidden."
                                }}
                            );
                        S0 ->
                            S0
                    end
                end,
                Structs
            )
        ],
    Json.

gen_struct(Ns, Name, #{fields := Fields} = Meta, Opts) ->
    Paths =
        case Meta of
            #{paths := Ps} -> lists:sort(maps:keys(Ps));
            _ -> []
        end,
    FullName = bin(hocon_schema:fmt_ref(Ns, Name)),
    ok = assert_unique_names(FullName, Fields),
    S0 = #{
        full_name => FullName,
        paths => [bin(P) || P <- Paths],
        tags => maps:get(tags, Meta, []),
        fields => fmt_fields(Ns, Fields, Opts)
    },
    case Meta of
        #{desc := StructDoc} ->
            case fmt_desc(StructDoc, Opts) of
                undefined ->
                    S0;
                Text ->
                    S0#{desc => Text}
            end;
        _ ->
            S0
    end.

assert_unique_names(FullName, Fields) ->
    Names = hocon_schema:names_and_aliases(Fields),
    case (Names -- lists:usort(Names)) of
        [] ->
            ok;
        Dups ->
            throw(#{
                reason => duplicated_field_names_and_aliases,
                path => FullName,
                duplicated => Dups
            })
    end.

fmt_fields(_Ns, [], _Opts) ->
    [];
fmt_fields(Ns, [{Name, FieldSchema} | Fields], Opts) ->
    case hocon_schema:is_hidden(FieldSchema, Opts) of
        true ->
            fmt_fields(Ns, Fields, Opts);
        _ ->
            FmtFieldFun = formatter_func(Opts),
            [FmtFieldFun(Ns, Name, FieldSchema, Opts) | fmt_fields(Ns, Fields, Opts)]
    end.

fmt_field(Ns, Name, FieldSchema, Opts) ->
    L =
        case hocon_schema:is_deprecated(FieldSchema) of
            true ->
                {since, Vsn} = hocon_schema:field_schema(FieldSchema, deprecated),
                [
                    {name, bin(Name)},
                    {importance, hocon_schema:field_schema(FieldSchema, importance)},
                    {aliases, hocon_schema:aliases(FieldSchema)},
                    {type, fmt_type(Ns, hocon_schema:field_schema(FieldSchema, type))},
                    {desc, bin(["Deprecated since ", Vsn, "."])}
                ];
            false ->
                Default = hocon_schema:field_schema(FieldSchema, default),
                [
                    {name, bin(Name)},
                    {importance, hocon_schema:field_schema(FieldSchema, importance)},
                    {aliases, hocon_schema:aliases(FieldSchema)},
                    {type, fmt_type(Ns, hocon_schema:field_schema(FieldSchema, type))},
                    {default, fmt_default(Default)},
                    {raw_default, Default},
                    {examples, examples(FieldSchema)},
                    {desc, fmt_desc(hocon_schema:field_schema(FieldSchema, desc), Opts)},
                    {extra, hocon_schema:field_schema(FieldSchema, extra)}
                ]
        end,
    maps:from_list([{K, V} || {K, V} <- L, V =/= undefined]).

examples(FieldSchema) ->
    case hocon_schema:field_schema(FieldSchema, examples) of
        undefined ->
            case hocon_schema:field_schema(FieldSchema, example) of
                undefined -> undefined;
                Example -> [Example]
            end;
        Examples ->
            Examples
    end.

fmt_default(undefined) ->
    undefined;
fmt_default(Value) ->
    OneLine = hocon_pp:do(Value, #{newline => "", embedded => true}),
    #{oneliner => true, hocon => bin(OneLine)}.

fmt_type(Ns, T) ->
    hocon_schema:fmt_type(Ns, T).

fmt_desc(Desc, #{desc_resolver := F}) when Desc =/= undefined ->
    case F(Desc) of
        undefined ->
            undefined;
        IoData ->
            try
                B = unicode:characters_to_binary(IoData, utf8),
                true = is_binary(B),
                B
            catch
                _:_ ->
                    throw(#{
                        reason => bad_desc_resolution,
                        reference => Desc,
                        resolution => IoData
                    })
            end
    end;
fmt_desc(_Desc, _) ->
    %% no resolver, no description needed at all for this schema dump
    undefined.

bin(undefined) -> undefined;
bin(S) when is_list(S) -> unicode:characters_to_binary(S, utf8);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(B) when is_binary(B) -> B.

formatter_func(Opts) ->
    maps:get(formatter, Opts, fun fmt_field/4).

%% @doc Dummy resolver just reutrns the reference as a binary.
%% If thre is a need to resolve the reference, a custom resolver
%% should be provided.
dummy_desc_resolver(?DESC(Namespace, Id)) ->
    %% hey, if you want to use gettext, parse the msgid: prefix
    bin(["msgid:", bin(Namespace), ".", bin(Id)]);
dummy_desc_resolver(Desc) ->
    bin(Desc).
