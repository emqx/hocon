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

-module(hocon_schema).

%% behaviour APIs
-export([
    roots/1,
    fields/2,
    translations/1,
    translation/2,
    validations/1
]).

-export([
    find_structs/1,
    find_structs/2,
    override/2,
    namespace/1,
    resolve_struct_name/2,
    root_names/1,
    field_schema/2,
    path/1,
    readable_type/1,
    fmt_type/2,
    fmt_ref/2,
    is_deprecated/1,
    is_hidden/2,
    aliases/1,
    name_and_aliases/1,
    names_and_aliases/1
]).

%% only for testing
-export([
    fields_and_meta/2
]).

-export_type([
    type/0,
    field/0,
    fields/0,
    field_schema/0,
    name/0,
    schema/0,
    typefunc/0,
    translationfunc/0,
    desc/0,
    union_members/0,
    union_selector/0,
    importance/0
]).

-callback namespace() -> name().
-callback roots() -> [root_type()].
-callback fields(name()) -> fields().
-callback translations() -> [name()].
-callback translation(name()) -> [translation()].
-callback validations() -> [validation()].
-callback desc(name()) -> desc() | undefined.
-callback tags() -> [tag()].

-optional_callbacks([
    translations/0,
    translation/1,
    validations/0,
    desc/1,
    tags/0
]).

-include("hoconsc.hrl").

-type name() :: atom() | string() | binary().
-type desc_id() :: atom() | string() | binary().
-type desc() :: iodata() | {desc, module(), desc_id()}.
-type union_selector() :: fun((all_union_members | {value, _}) -> type() | [type()]).
-type union_members() :: [type()] | union_selector().
-type importance() :: ?IMPORTANCE_HIGH | ?IMPORTANCE_MEDIUM | ?IMPORTANCE_LOW | ?IMPORTANCE_HIDDEN.
%% primitive (or complex, but terminal) type
-type type() ::
    typerefl:type()
    %% reference to another struct
    | name()
    %% array of
    | ?ARRAY(type())
    %% one-of
    | ?UNION(union_members(), _)
    %% one-of atoms, data is allowed to be binary()
    | ?ENUM([atom()]).

-type field_schema() ::
    typerefl:type()
    | ?UNION(union_members(), _)
    | ?ARRAY(type())
    | ?ENUM(type())
    | field_schema_map()
    | field_schema_fun().

-type field_schema_fun() :: fun((_) -> _).
-type field_schema_map() ::
    #{
        type := type(),
        default => term(),
        examples => term(),
        mapping => undefined | string(),
        converter => undefined | translationfunc(),
        validator => undefined | validationfun(),
        %% set false if a field is allowed to be `undefined`
        %% NOTE: has no point setting it to `true` if field has a default value

        % default = false
        required => boolean() | {false, recursively},
        %% for sensitive data obfuscation (password, token)
        sensitive => boolean(),
        desc => desc(),
        %% hide it from doc generation
        importance => importance(),
        %% Set to {since, Version} to mark field as deprecated.
        %% deprecated field can not be removed due to compatibility reasons.
        %% The value will be dropped,
        %% Deprecated fields are treated as required => {false, recursively}
        deprecated => {since, binary() | string()} | false,
        %% Other names to reference this field.
        %% this can be useful when we need to rename some filed names
        %% while keeping backward compatibility.
        %% For one struct, no duplication is allowed in the collection of
        %% all field names and aliases.
        %% The no-duplication assertion is made when dumping the schema to JSON.
        %% see `hocon_schema_json'.
        %% When checking values against the schema, the look up is first
        %% done with the current field name, if not found, try the aliases
        %% in the defined order until one is found (i.e. first match wins).
        aliases => [name()],
        %% transparent metadata
        extra => map()
    }.

-type field() :: {name(), typefunc() | field_schema()}.
-type fields() ::
    [field()]
    | #{
        fields := [field()],
        desc => desc()
    }.
-type validation() :: {name(), validationfun()}.
-type root_type() :: name() | field().
-type schema() ::
    module()
    | #{
        roots := [root_type()],
        fields => #{name() => fields()} | fun((name()) -> fields()),
        %% for config mappings
        translations => #{name() => [translation()]},
        %% for config integrity checks
        validations => [validation()],
        tags => [tag()],
        namespace => atom()
    }.

-type translation() :: {name(), translationfunc()}.
-type typefunc() :: fun((_) -> _).
-type translationfunc() ::
    fun((hocon:config()) -> hocon:config())
    | fun((hocon:config(), map()) -> hocon:config()).
-type validationfun() :: fun((hocon:config()) -> ok | boolean() | {error, term()}).
-type bin_name() :: binary().
-type tag() :: binary().

-type find_structs_opts() :: #{
    include_importance_up_from => importance(),
    _ => _
}.

%% @doc Get translation identified by `Name' from the given schema.
-spec translation(schema(), name()) -> [translation()].
translation(Mod, Name) when is_atom(Mod) -> Mod:translation(Name);
translation(#{translations := Trs}, Name) -> maps:get(Name, Trs).

%% @doc Get all translations from the given schema.
-spec translations(schema()) -> [name()].
translations(Mod) when is_atom(Mod) ->
    case erlang:function_exported(Mod, translations, 0) of
        false -> [];
        true -> Mod:translations()
    end;
translations(#{translations := Trs}) ->
    maps:keys(Trs);
translations(Sc) when is_map(Sc) -> [].

%% @doc Get all validations from the given schema.
-spec validations(schema()) -> [validation()].
validations(Mod) when is_atom(Mod) ->
    case erlang:function_exported(Mod, validations, 0) of
        false -> [];
        true -> Mod:validations()
    end;
validations(Sc) ->
    maps:get(validations, Sc, []).

%% @doc Make a higher order schema by overriding `Base' with `OnTop'
-spec override(field_schema(), field_schema_map()) -> field_schema_fun().
override(Base, OnTop) ->
    fun(SchemaKey) ->
        case maps:is_key(SchemaKey, OnTop) of
            true -> field_schema(OnTop, SchemaKey);
            false -> field_schema(Base, SchemaKey)
        end
    end.

%% @doc Get namespace of a schema.
-spec namespace(schema()) -> undefined | binary().
namespace(Schema) ->
    case is_atom(Schema) of
        true ->
            Schema:namespace();
        false ->
            maps:get(namespace, Schema, undefined)
    end.

%% @doc Resolve struct name from a guess.
resolve_struct_name(Schema, StructName) ->
    case lists:keyfind(bin(StructName), 1, roots(Schema)) of
        {_, {N, _Sc}} -> N;
        false -> throw({unknown_struct_name, Schema, StructName})
    end.

%% @doc Get all root names from a schema.
-spec root_names(schema()) -> [binary()].
root_names(Schema) -> [Name || {Name, _} <- roots(Schema)].

%% @doc Get exported root fields in format [{BinaryName, {OriginalName, FieldSchema}}].
-spec roots(schema()) -> [{bin_name(), {name(), field_schema()}}].
roots(Schema) ->
    All =
        lists:map(
            fun
                ({N, T}) -> {bin(N), {N, T}};
                (N) when is_atom(Schema) -> {bin(N), {N, ?R_REF(Schema, N)}};
                (N) -> {bin(N), {N, ?REF(N)}}
            end,
            do_roots(Schema)
        ),
    AllNames = [Name || {Name, _} <- All],
    UniqueNames = lists:usort(AllNames),
    case length(UniqueNames) =:= length(AllNames) of
        true ->
            All;
        false ->
            error({duplicated_root_names, AllNames -- UniqueNames})
    end.

do_roots(Mod) when is_atom(Mod) -> Mod:roots();
do_roots(#{roots := Names}) -> Names.

%% @doc Get fields of the struct for the given struct name.
-spec fields(schema(), name()) -> [field()].
fields(Sc, Name) ->
    #{fields := Fields} = fields_and_meta(Sc, Name),
    Fields.

%% @doc Get fields and meta data of the struct for the given struct name.
-spec fields_and_meta(schema(), name()) -> fields().
fields_and_meta(Mod, Name) when is_atom(Mod) ->
    Meta =
        try Mod:fields(Name) of
            Fields when is_list(Fields) ->
                maybe_add_desc(Mod, Name, #{fields => Fields});
            Fields ->
                ensure_struct_meta(Fields)
        catch
            K:E:S ->
                throw(#{kind => K, reason => E, stacktrace => S})
        end,
    Meta#{tags => tags(Mod)};
fields_and_meta(#{fields := Fields}, Name) when is_function(Fields) ->
    ensure_struct_meta(Fields(Name));
fields_and_meta(#{fields := Fields}, Name) when is_map(Fields) ->
    ensure_struct_meta(maps:get(Name, Fields)).

maybe_add_desc(Mod, Name, Meta) ->
    case erlang:function_exported(Mod, desc, 1) of
        true ->
            try Mod:desc(Name) of
                undefined ->
                    Meta;
                Desc ->
                    Meta#{desc => Desc}
            catch
                K:E:S ->
                    throw(#{kind => K, reason => E, stacktrace => S})
            end;
        false ->
            Meta
    end.

tags(Mod) when is_atom(Mod) ->
    case erlang:function_exported(Mod, tags, 0) of
        true ->
            Mod:tags();
        false ->
            []
    end.

ensure_struct_meta(Fields) when is_list(Fields) -> #{fields => Fields};
ensure_struct_meta(#{fields := _} = Fields) -> Fields.

find_structs_loop(Schema, Fields, Opts) ->
    find_structs_loop(Schema, Fields, #{}, _ValueStack = [], _TypeStack = [], Opts).

find_structs_loop(Schema, #{fields := Fields}, Acc, Stack, TStack, Opts) ->
    find_structs_loop(Schema, Fields, Acc, Stack, TStack, Opts);
find_structs_loop(_Schema, [], Acc, _Stack, _TStack, _Opts) ->
    Acc;
find_structs_loop(Schema, [{FieldName, FieldSchema} | Fields], Acc0, Stack, TStack, Opts) ->
    case is_hidden(FieldSchema, Opts) of
        true ->
            %% hidden root
            find_structs_loop(Schema, Fields, Acc0, Stack, TStack, Opts);
        false ->
            Type = field_schema(FieldSchema, type),
            Acc = find_structs_per_type(Schema, Type, Acc0, [str(FieldName) | Stack], TStack, Opts),
            find_structs_loop(Schema, Fields, Acc, Stack, TStack, Opts)
    end.

find_structs_per_type(Schema, Name, Acc, Stack, TStack, Opts) when is_list(Name) ->
    find_ref(Schema, Name, Acc, Stack, TStack, Opts);
find_structs_per_type(Schema, ?REF(Name), Acc, Stack, TStack, Opts) ->
    find_ref(Schema, Name, Acc, Stack, TStack, Opts);
find_structs_per_type(_Schema, ?R_REF(Module, Name), Acc, Stack, TStack, Opts) ->
    find_ref(Module, Name, Acc, Stack, TStack, Opts);
find_structs_per_type(Schema, ?LAZY(Type), Acc, Stack, TStack, Opts) ->
    find_structs_per_type(Schema, Type, Acc, Stack, TStack, Opts);
find_structs_per_type(Schema, ?ARRAY(Type), Acc, Stack, TStack, Opts) ->
    find_structs_per_type(Schema, Type, Acc, ["$INDEX" | Stack], TStack, Opts);
find_structs_per_type(Schema, ?UNION(Types0, _), Acc, Stack, TStack, Opts) ->
    Types = hoconsc:union_members(Types0),
    lists:foldl(
        fun(T, AccIn) ->
            find_structs_per_type(Schema, T, AccIn, Stack, TStack, Opts)
        end,
        Acc,
        Types
    );
find_structs_per_type(Schema, ?MAP(NameType, Type), Acc, Stack, TStack, Opts) ->
    find_structs_per_type(
        Schema, Type, Acc, ["$" ++ str(get_map_key_type_name(NameType)) | Stack], TStack, Opts
    );
find_structs_per_type(_Schema, _Type, Acc, _Stack, _TStack, _Opts) ->
    Acc.

get_map_key_type_name(Fun) when is_function(Fun, 1) ->
    case Fun(name) of
        undefined ->
            name;
        Name ->
            Name
    end;
get_map_key_type_name(Map) when is_map(Map) ->
    maps:get(name, Map, name);
get_map_key_type_name(Name) ->
    Name.

find_ref(Schema, Name, Acc, Stack, TStack, Opts) ->
    Namespace = namespace(Schema),
    Key = {Namespace, Schema, Name},
    Path = path(Stack),
    Paths0 =
        case maps:find(Key, Acc) of
            {ok, #{paths := Ps}} -> Ps;
            error -> #{}
        end,
    case lists:member(Key, TStack) of
        true ->
            %% loop reference, break here, otherwise never exit
            Acc;
        false ->
            Fields0 = fields_and_meta(Schema, Name),
            Paths = Paths0#{Path => true},
            Fields1 = drop_hidden(Fields0, Opts),
            Fields = Fields1#{paths => Paths},
            find_structs_loop(Schema, Fields, Acc#{Key => Fields}, Stack, [Key | TStack], Opts)
    end.

drop_hidden(#{fields := Fields} = Meta, Opts) ->
    NewFields = lists:filter(fun({_N, Sc}) -> not is_hidden(Sc, Opts) end, Fields),
    Meta#{fields => NewFields}.

%% @doc Collect all structs defined in the given schema.  Used for
%% exporting the schema to other formats such as JSON.
-spec find_structs(schema()) ->
    {RootNs :: name(), RootFields :: [field()], [{Namespace :: name(), Name :: name(), fields()}]}.
find_structs(Schema) ->
    find_structs(Schema, #{}).

-spec find_structs(schema(), find_structs_opts()) ->
    {RootNs :: name(), RootFields :: [field()], [{Namespace :: name(), Name :: name(), fields()}]}.
find_structs(Schema, Opts) ->
    RootFields = unify_roots(Schema, Opts),
    ok = assert_no_dot_in_root_names(Schema, RootFields),
    All = lists:keysort(1, maps:to_list(find_structs_loop(Schema, RootFields, Opts))),
    RootNs = hocon_schema:namespace(Schema),
    Unified = lists:map(
        fun({{Ns, _Schema, Name}, Fields}) ->
            {Ns, Name, Fields}
        end,
        All
    ),
    {RootNs, RootFields, Unified}.

unify_roots(Schema, Opts) ->
    Roots0 = ?MODULE:roots(Schema),
    Roots1 = lists:map(
        fun({_BinName, {RootFieldName, RootFieldSchema}}) ->
            {RootFieldName, RootFieldSchema}
        end,
        Roots0
    ),
    lists:filter(
        fun({_RootFieldName, RootFieldSchema}) ->
            not is_hidden(RootFieldSchema, Opts)
        end,
        Roots1
    ).

str(A) when is_atom(A) -> atom_to_list(A);
str(S) when is_list(S) -> S.

bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(S) -> unicode:characters_to_binary(S, utf8).

%% get type validation stack.
path(Stack) when is_list(Stack) ->
    string:join(lists:reverse(lists:map(fun str/1, Stack)), ".").

field_schema(Atom, type) when is_atom(Atom) -> Atom;
field_schema(Atom, _Other) when is_atom(Atom) -> undefined;
field_schema(Type, SchemaKey) when ?IS_TYPEREFL(Type) ->
    field_schema(hoconsc:mk(Type), SchemaKey);
field_schema(?MAP(_Name, _Type) = Map, SchemaKey) ->
    field_schema(hoconsc:mk(Map), SchemaKey);
field_schema(?LAZY(_) = Lazy, SchemaKey) ->
    field_schema(hoconsc:mk(Lazy), SchemaKey);
field_schema(Ref, SchemaKey) when is_list(Ref) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?REF(_) = Ref, SchemaKey) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?R_REF(_, _) = Ref, SchemaKey) ->
    field_schema(hoconsc:mk(Ref), SchemaKey);
field_schema(?ARRAY(_) = Array, SchemaKey) ->
    field_schema(hoconsc:mk(Array), SchemaKey);
field_schema(?UNION(_, _) = Union, SchemaKey) ->
    field_schema(hoconsc:mk(Union), SchemaKey);
field_schema(?ENUM(_) = Enum, SchemaKey) ->
    field_schema(hoconsc:mk(Enum), SchemaKey);
field_schema(FieldSchema, SchemaKey) when is_function(FieldSchema, 1) ->
    FieldSchema(SchemaKey);
field_schema(FieldSchema, SchemaKey) when is_map(FieldSchema) ->
    maps:get(SchemaKey, FieldSchema, undefined).

readable_type(T) ->
    case fmt_type(undefined, T) of
        #{name := Name} -> Name;
        #{kind := Kind} -> Kind
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
fmt_type(Ns, ?UNION(Ts, DisplayName)) ->
    #{
        kind => union,
        members => [fmt_type(Ns, T) || T <- hoconsc:union_members(Ts)],
        display_name => DisplayName
    };
fmt_type(_Ns, ?ENUM(Symbols)) ->
    #{
        kind => enum,
        symbols => [bin(S) || S <- Symbols]
    };
fmt_type(Ns, ?LAZY(T)) ->
    fmt_type(Ns, T);
fmt_type(Ns, ?MAP(NameType, T)) ->
    #{
        kind => map,
        name => bin(get_map_key_type_name(NameType)),
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
        true -> Name;
        false -> <<(bin(Ns))/binary, ":", (bin(Name))/binary>>
    end.

%% @doc Return 'true' if the field is marked as deprecated.
-spec is_deprecated(field_schema()) -> boolean().
is_deprecated(Schema) ->
    IsDeprecated = field_schema(Schema, deprecated),
    IsDeprecated =/= undefined andalso IsDeprecated =/= false.

%% @doc Return 'true' if the field has an importance less than or equal to the
%% provided minimum importance level.
-spec is_hidden(field_schema(), find_structs_opts()) -> boolean().
is_hidden(Schema, Opts) ->
    NeededImportance = maps:get(
        include_importance_up_from,
        Opts,
        ?DEFAULT_INCLUDE_IMPORTANCE_UP_FROM
    ),
    DefinedImprotance =
        case field_schema(Schema, importance) of
            undefined -> ?DEFAULT_IMPORTANCE;
            I -> I
        end,
    importance_num(DefinedImprotance) < importance_num(NeededImportance).

importance_num(?IMPORTANCE_HIDDEN) -> 0;
importance_num(?IMPORTANCE_LOW) -> 7;
importance_num(?IMPORTANCE_MEDIUM) -> 8;
importance_num(?IMPORTANCE_HIGH) -> 9.

%% @doc Return the aliases in a list.
-spec aliases(field_schema()) -> [name()].
aliases(Schema) ->
    case field_schema(Schema, aliases) of
        undefined ->
            [];
        Names ->
            lists:map(fun bin/1, Names)
    end.

%% @doc Return the names and aliases in a list.
%% The head of the list must be the current name.
-spec name_and_aliases(field()) -> [name()].
name_and_aliases({Name, Schema}) ->
    [bin(Name) | aliases(Schema)].

%% HOCON fields are allowed to have dots in the name,
%% however we do not support it in the root names.
%%
%% This is because the dot will cause root name to be split,
%% which in turn makes the implementation of hocon_tconf module complicated.
%%
%% e.g. if a root name is 'a.b.c', the schema is only defined
%% for data below `c` level.
%% `a` and `b` are implicitly single-field roots.
%%
%% In this case if a non map value is assigned, such as `a.b=1`,
%% the check code will crash rather than reporting a useful error reason.
assert_no_dot_in_root_names(Schema, Roots) ->
    Names = names_and_aliases(Roots),
    ok = lists:foreach(fun(Name) -> assert_no_dot(Schema, Name) end, Names).

assert_no_dot(Schema, RootName) ->
    case hocon_util:split_path(RootName) of
        [_] ->
            ok;
        _ ->
            error(#{
                reason => bad_root_name,
                root_name => RootName,
                schema => Schema
            })
    end.

%% @doc Return all fields' names and aliases in a list.
-spec names_and_aliases([field()]) -> [name()].
names_and_aliases(Fields) ->
    lists:flatmap(fun hocon_schema:name_and_aliases/1, Fields).
