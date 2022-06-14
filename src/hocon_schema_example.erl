%%--------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon_schema_example).
-include_lib("hocon/include/hoconsc.hrl").

-elvis([{elvis_style, dont_repeat_yourself, disable}]).

-export([gen/2]).

-define(COMMENT, "#  ").
-define(COMMENT2, "## ").
-define(INDENT, "  ").
-define(NL, io_lib:nl()).
-define(DOC, "@doc ").
-define(TYPE, "@type ").
-define(PATH, "@path ").
-define(LINK, "@link ").
-define(DEFAULT, "@default ").
-define(BIND, " = ").

gen(Schema, undefined) ->
    gen(Schema, "# HOCON Example");
gen(Schema, Title) when is_list(Title) orelse is_binary(Title) ->
    gen(Schema, #{title => Title, body => <<>>});
gen(Schema, #{title := Title, body := Body} = Opts) ->
    File = maps:get(desc_file, Opts, undefined),
    Lang = maps:get(lang, Opts, "en"),
    [Roots | Fields] = hocon_schema_json:gen(Schema, #{desc_file => File, lang => Lang}),
    FmtOpts = #{tid => new_cache(), indent => "", comment => false, hidden_meta => false},
    lists:foreach(
        fun(F = #{full_name := Name}) -> insert(FmtOpts, {{full_name, Name}, F}) end, Fields
    ),
    #{fields := RootKeys} = Roots,
    try
        Structs = lists:map(
            fun(Root) ->
                [
                    fmt_desc(Root, ""),
                    fmt_field(Root, "", FmtOpts)
                ]
            end,
            RootKeys
        ),
        [
            ?COMMENT2,
            Title,
            ?NL,
            ?NL,
            ?COMMENT2,
            Body,
            ?NL,
            ?NL,
            Structs
        ]
    after
        delete_cache(FmtOpts)
    end.

fmt_field(
    #{type := #{kind := struct, name := SubName} = Type, name := Name} = Field,
    Path0,
    Opts0
) ->
    {PathName, ValName} = resolve_name(Name),
    Path = [str(PathName) | Path0],
    {Link, Opts1} = fmt_struct_link(Type, Path, Opts0),
    {ok, #{fields := SubFields}} = find_struct_sub_fields(SubName, Opts1),
    #{indent := Indent, comment := Comment} = Opts0,
    Opts2 = Opts1#{indent => Indent ++ ?INDENT},

    SubStructs =
        case maps:get(examples, Field, #{}) of
            #{} = Example ->
                fmt_field_with_example(Path, SubFields, Example, Opts2);
            {union, UnionExamples} ->
                Examples1 = filter_union_example(UnionExamples, SubFields),
                fmt_field_with_example(Path, SubFields, Examples1, Opts2);
            {array, ArrayExamples} ->
                lists:flatmap(
                    fun(SubExample) ->
                        fmt_field_with_example(Path, SubFields, SubExample, Opts2)
                    end,
                    ArrayExamples
                )
        end,
    [
        fmt_path(Path, Indent),
        Link,
        Indent,
        comment(Comment),
        ValName,
        " {",
        ?NL,
        lists:join(?NL, SubStructs),
        Indent,
        comment(Comment),
        " }",
        ?NL
    ];
fmt_field(#{type := #{kind := primitive, name := TypeName}} = Field, Path, Opts) ->
    Name = str(maps:get(name, Field)),
    Fix = fmt_fix_header(Field, TypeName, [Name | Path], Opts),
    [Fix, fmt_examples(Name, Field, Opts)];
fmt_field(#{type := #{kind := singleton, name := SingleTon}} = Field, Path, Opts) ->
    Name = str(maps:get(name, Field)),
    #{indent := Indent, comment := Comment} = Opts,
    Fix = fmt_fix_header(Field, "singleton", [Name | Path], Opts),
    [Fix, fmt(Indent, Comment, Name, SingleTon)];
fmt_field(#{type := #{kind := enum, symbols := Symbols}} = Field, Path, Opts) ->
    TypeName = ["enum: ", lists:join(" | ", Symbols)],
    Name = str(maps:get(name, Field)),
    Fix = fmt_fix_header(Field, TypeName, [str(Name) | Path], Opts),
    [Fix, fmt_examples(Name, Field, Opts)];
fmt_field(#{type := #{kind := union, members := Members0} = Type} = Field, Path0, Opts0) ->
    Name = str(maps:get(name, Field)),
    Names = lists:map(fun(#{name := N}) -> N end, Members0),
    Path = [Name | Path0],
    TypeStr = ["union() ", lists:join(" | ", Names)],
    Fix = fmt_fix_header(Field, TypeStr, Path, Opts0),
    {Link, Opts1} = fmt_union_link(Type, Path, Opts0),
    #{indent := Indent} = Opts1,
    Indent1 = Indent ++ ?INDENT,
    Opts2 = Opts1#{indent => Indent1},
    fallback_to_example(Field, [Fix, Link], Indent1, Name, Opts2, Indent, "");
fmt_field(#{type := #{kind := map, name := MapName} = Type} = Field, Path0, Opts) ->
    Name = str(maps:get(name, Field)),
    #{indent := Indent} = Opts,
    Path = [Name | Path0],
    Path1 = ["$" ++ str(MapName) | Path],
    Fix = fmt_fix_header(Field, "map_struct()", Path, Opts),
    Link = fmt_map_link(Path1, Type, Opts),
    Fix1 = [Fix, Link],
    case Link =:= "" andalso need_comment_example(map, Opts, Path1) of
        true ->
            Indent1 = Indent ++ ?INDENT,
            Opts1 = Opts#{indent => Indent1, comment => true},
            ValFields = fmt_sub_fields(Opts1, Field, Path),
            [Fix1, Indent1, ?COMMENT, Name, ".", str(MapName), ?BIND, ?NL, ValFields, ?NL];
        false ->
            [Fix1, ?NL]
    end;
fmt_field(#{type := #{kind := array} = Type} = Field, Path0, Opts) ->
    #{indent := Indent} = Opts,
    Name = str(maps:get(name, Field)),
    Path = [Name | Path0],
    Fix = fmt_fix_header(Field, "array()", Path, Opts),
    Link = fmt_array_link(Type, Path, Opts),
    Fix1 = [Fix, Link],
    Indent1 = Indent ++ ?INDENT,
    Opts1 = Opts#{indent => Indent1},
    fallback_to_example(Field, Fix1, Indent1, Name, Opts1, Indent, "[]").

fmt(Indent, Comment, Name, Value) ->
    [Indent, comment(Comment), Name, ?BIND, Value, ?NL].

fallback_to_example(Field, Fix1, Indent1, Name, Opts, Indent, Default) ->
    #{comment := Comment} = Opts,
    case Field of
        #{examples := [First | Examples]} ->
            [
                [
                    Fix1,
                    Indent,
                    comment(Comment),
                    Name,
                    ?BIND,
                    fmt_example(First, Opts),
                    ?NL
                ]
                | lists:map(
                    fun(E) ->
                        [Indent1, ?COMMENT, Name, ?BIND, fmt_example(E, Opts), ?NL]
                    end,
                    Examples
                )
            ];
        _ ->
            Default2 =
                case get_default(Field, Opts) of
                    undefined -> Default;
                    Default1 -> Default1
                end,
            case Default2 of
                "" -> [Fix1, Indent, ?COMMENT, Name, ?BIND, Default2, ?NL];
                _ -> [Fix1, Indent, comment(Comment), Name, ?BIND, Default2, ?NL]
            end
    end.

fmt_field_with_example(Path, SubFields, Examples, Opts1) ->
    lists:map(
        fun(F) ->
            #{name := N} = F,
            case maps:find(N, Examples) of
                {ok, SubExample} ->
                    fmt_field(F#{examples => SubExample}, Path, Opts1);
                error ->
                    fmt_field(F, Path, Opts1)
            end
        end,
        SubFields
    ).

find_struct_sub_fields(Name, Opts) ->
    find(Opts, {full_name, Name}).

fmt_sub_fields(Opts, Field, Path) ->
    {SubFields, Opts1} = get_sub_fields(Field, Opts),
    [fmt_field(F, Path, Opts1) || F <- SubFields].

get_sub_fields(#{type := #{kind := map, values := ValT, name := MapName0}} = _Field, Opts) ->
    MapName = "$" ++ str(MapName0),
    {[#{name => {MapName, ""}, type => ValT}], Opts}.

filter_union_example(Examples0, SubFields) ->
    TargetKeys = lists:sort([binary_to_atom(Name) || #{name := Name} <- SubFields]),
    Examples =
        lists:filtermap(
            fun(Example) ->
                case lists:all(fun(K) -> lists:member(K, TargetKeys) end, maps:keys(Example)) of
                    true -> {true, ensure_bin_key(Example)};
                    false -> false
                end
            end,
            Examples0
        ),
    case Examples of
        [Example] -> Example;
        [] -> #{};
        Other -> throw({error, {find_union_example_failed, Examples, SubFields, Other}})
    end.

ensure_bin_key(Map) when is_map(Map) ->
    maps:fold(
        fun
            (K0, V0 = #{}, Acc) -> Acc#{bin(K0) => ensure_bin_key(V0)};
            (K0, V, Acc) -> Acc#{bin(K0) => V}
        end,
        #{},
        Map
    );
ensure_bin_key(List) when is_list(List) -> [ensure_bin_key(Map) || Map <- List];
ensure_bin_key(Term) ->
    Term.

fmt_desc(#{desc := Desc0}, Indent) ->
    Target = iolist_to_binary([?NL, Indent, ?COMMENT2]),
    Desc = string:trim(Desc0, both),
    [Indent, ?COMMENT2, ?DOC, binary:replace(Desc, [<<"\n">>], Target, [global]), ?NL];
fmt_desc(_, _) ->
    <<"">>.

fmt_type(Type, Indent) ->
    [Indent, ?COMMENT2, ?TYPE, Type, ?NL].

fmt_path(Path, Indent) -> [Indent, ?COMMENT2, ?PATH, hocon_schema:path(Path), ?NL].

fmt_fix_header(Field, Type, Path, #{indent := Indent}) ->
    [
        fmt_desc(Field, Indent),
        fmt_path(Path, Indent),
        fmt_type(Type, Indent),
        fmt_default(Field, Indent)
    ].

fmt_map_link(Path0, Type, Opts) ->
    case Type of
        #{values := #{name := ValueName}} ->
            fmt_map_link2(Path0, ValueName, Opts);
        #{values := #{members := Members}} ->
            lists:map(fun(M) -> fmt_map_link(Path0, M, Opts) end, Members);
        _ ->
            []
    end.

fmt_map_link2(Path0, ValueName, Opts) ->
    PathStr = hocon_schema:path(Path0),
    Path = bin(PathStr),
    #{indent := Indent} = Opts,
    case find(Opts, {map, PathStr}) of
        {ok, Link} ->
            [Indent, ?COMMENT2, ?LINK, Link, ?NL];
        {error, not_found} ->
            Paths =
                case find_struct_sub_fields(ValueName, Opts) of
                    {ok, #{paths := SubPaths}} -> SubPaths;
                    _ -> []
                end,
            case lists:member(Path, Paths) of
                true ->
                    insert(Opts, [{{map, binary_to_list(P)}, Path} || P <- Paths, P =/= Path]);
                false ->
                    ok
            end,
            ""
    end.

fmt_struct_link(Type, Path, Opts = #{indent := Indent}) ->
    case find(Opts, {struct, Type}) of
        {ok, Link} ->
            {link(Link, Indent), Opts#{link => true}};
        {error, not_found} ->
            insert(Opts, {{struct, Type}, Path}),
            {"", Opts}
    end.

fmt_union_link(Type = #{members := Members}, Path, Opts = #{indent := Indent}) ->
    case find(Opts, {union, Type}) of
        {ok, Link} ->
            {link(Link, Indent), Opts};
        {error, not_found} ->
            case is_simple_type(Members) of
                true -> ok;
                false -> insert(Opts, {{union, Type}, Path})
            end,
            {"", Opts}
    end.

fmt_array_link(Type = #{elements := ElemT}, Path, Opts = #{indent := Indent}) ->
    case find(Opts, {array, Type}) of
        {ok, Link} ->
            link(Link, Indent);
        {error, not_found} ->
            case is_simple_type(ElemT) of
                true -> ok;
                false -> insert(Opts, {{array, Type}, Path})
            end,
            ""
    end.

link(Link, Indent) ->
    [Indent, ?COMMENT2, ?LINK, hocon_schema:path(Link), ?NL].

is_simple_type(Types) when is_list(Types) ->
    lists:all(
        fun(#{kind := Kind}) ->
            Kind =:= primitive orelse Kind =:= singleton
        end,
        Types
    );
is_simple_type(Type) ->
    is_simple_type([Type]).

need_comment_example(map, Opts, Path) ->
    case find(Opts, {map, hocon_schema:path(Path)}) of
        {ok, _} -> false;
        {error, not_found} -> true
    end.

fmt_examples(Name, #{examples := Examples}, Opts) ->
    #{indent := Indent, comment := Comment} = Opts,
    lists:map(
        fun(E) ->
            case fmt_example(E, Opts) of
                [""] -> [Indent, ?COMMENT, Name, ?BIND, ?NL];
                E1 -> [Indent, comment(Comment), Name, ?BIND, E1, ?NL]
            end
        end,
        ensure_list(Examples)
    );
fmt_examples(Name, Field, Opts = #{indent := Indent, comment := Comment}) ->
    case get_default(Field, Opts) of
        undefined -> [Indent, ?COMMENT, Name, ?BIND, ?NL];
        Default -> fmt(Indent, Comment, Name, Default)
    end.

ensure_list(L) when is_list(L) -> L;
ensure_list(T) -> [T].

fmt_example({union, Value}, Opts) ->
    fmt_example(Value, Opts);
fmt_example(Value, #{indent := Indent0, comment := Comment}) ->
    case hocon_pp:do(ensure_bin_key(Value), #{newline => "", embedded => true}) of
        [] ->
            [?NL, Indent0, ?COMMENT, ?NL];
        [OneLine] ->
            [try_to_remove_quote(OneLine)];
        Lines ->
            Indent = Indent0 ++ ?INDENT,
            Target = iolist_to_binary([?NL, Indent, comment(Comment)]),
            [
                ?NL,
                Indent,
                comment(Comment),
                binary:replace(bin(Lines), [<<"\n">>], Target, [global]),
                ?NL
            ]
    end.

fmt_default(Field, Indent) ->
    case get_default(Field, #{indent => Indent, comment => true}) of
        undefined -> "";
        Default -> [Indent, ?COMMENT2, ?DEFAULT, Default, ?NL]
    end.

get_default(#{raw_default := Default}, Opts) when is_map(Opts) ->
    fmt_example(Default, Opts);
get_default(_, _Opts) ->
    undefined.

-define(RE, <<"^[A-Za-z0-9\"]+$">>).

try_to_remove_quote(Content) ->
    case re:run(Content, ?RE) of
        nomatch ->
            Content;
        _ ->
            case string:trim(Content, both, [$"]) of
                <<"">> -> Content;
                Other -> Other
            end
    end.

bin(S) when is_list(S) -> unicode:characters_to_binary(S, utf8);
bin(Atom) when is_atom(Atom) -> atom_to_binary(Atom);
bin(Int) when is_integer(Int) -> integer_to_binary(Int);
bin(Bin) -> Bin.

str(A) when is_atom(A) -> atom_to_list(A);
str(S) when is_list(S) -> S;
str(B) when is_binary(B) -> binary_to_list(B);
str({KeyName, _ValName}) -> str(KeyName).

comment(true) -> ?COMMENT;
comment(false) -> "".

new_cache() ->
    ets:new(?MODULE, [private, set, {keypos, 1}]).

delete_cache(#{tid := Tid}) ->
    ets:delete(Tid).

find(#{tid := Tid}, Key) ->
    case ets:lookup(Tid, Key) of
        [{_, Value}] -> {ok, Value};
        [] -> {error, not_found}
    end.

insert(#{tid := Tid}, Item) ->
    ets:insert(Tid, Item).

resolve_name({N1, N2}) -> {N1, N2};
resolve_name(N) -> {N, N}.
