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

-module(hocon_schema_md).

-export([gen/2, gen_from_structs/2]).

gen(Schema, undefined) ->
    gen(Schema, "# HOCON Document");
gen(Schema, Title) when is_list(Title) orelse is_binary(Title) ->
    gen(Schema, #{title => Title, body => <<>>});
gen(Schema, Opts0) ->
    Opts = ensure_env_prefix_opt(Opts0),
    Structs = hocon_schema_json:gen(Schema, Opts),
    gen_from_structs(Structs, Opts).

gen_from_structs(Structs, #{title := Title, body := Body} = Opts) ->
    [
        Title,
        "\n",
        Body,
        "\n",
        fmt_structs(2, Structs, Opts)
    ].

ensure_env_prefix_opt(Opts) ->
    maps:merge(#{env_prefix => "EMQX_"}, Opts).

fmt_structs(_Weight, [], _) ->
    [];
fmt_structs(Weight, [Struct | Rest], Opts) ->
    [
        fmt_struct(Weight, Struct, Opts),
        "\n"
        | fmt_structs(Weight, Rest, Opts)
    ].

fmt_struct(
    Weight,
    #{
        full_name := FullName,
        paths := Paths,
        fields := Fields
    } = Struct,
    Opts
) ->
    [
        hocon_md:h(Weight, FullName),
        maps:get(desc, Struct, ""),
        "\n\n",
        fmt_paths(Paths),
        fmt_envs(Paths, Opts),
        "\n\n**Fields**\n\n",
        lists:map(fun(F) -> fmt_field(F, Opts) end, Fields)
    ].

fmt_paths([]) ->
    [];
fmt_paths(Paths) ->
    [
        "\n**Config paths**\n\n",
        simple_list(Paths),
        "\n"
    ].

fmt_envs([], _) ->
    [];
fmt_envs(Paths, Opts) ->
    [
        "\n**Env overrides**\n\n",
        simple_list([fmt_env(P, Opts) || P <- Paths]),
        "\n"
    ].

fmt_env(Path, #{env_prefix := Prefix}) ->
    [Prefix, hocon_util:path_to_env_name(Path)].

simple_list(L) ->
    [[" - ", hocon_md:code(I), "\n"] || I <- L].

fmt_field(
    #{
        name := Name,
        type := Type
    } = Field,
    _Opts
) ->
    Default = fmt_default(maps:get(default, Field, undefined)),
    Desc = maps:get(desc, Field, ""),
    [
        ["- ", Name, ": ", fmt_type(Type), "\n"],
        case Default =/= undefined of
            true -> [hocon_md:indent(2, ["* default: ", Default]), "\n"];
            false -> []
        end,
        case Desc =/= undefined of
            true -> ["\n", hocon_md:indent(2, [Desc]), "\n"];
            false -> []
        end,
        "\n"
    ].

fmt_default(undefined) -> undefined;
fmt_default(#{oneliner := true, hocon := Content}) -> ["`", Content, "`"];
fmt_default(#{oneliner := false, hocon := Content}) -> ["\n```\n", Content, "```"].

fmt_type(T) -> hocon_md:code(do_type(T)).

do_type(#{kind := <<Kind/binary>>} = Type) ->
    do_type(Type#{kind := binary_to_atom(Kind)});
do_type(#{kind := primitive, name := Name}) ->
    Name;
do_type(#{kind := singleton, name := Name}) ->
    Name;
do_type(#{kind := struct, name := Ref}) ->
    hocon_md:local_link(Ref, Ref);
do_type(#{kind := array, elements := ElemT}) ->
    ["[", do_type(ElemT), "]"];
do_type(#{kind := union, members := Ts}) ->
    lists:join(" | ", [do_type(T) || T <- Ts]);
do_type(#{kind := enum, symbols := Symbols}) ->
    lists:join(" | ", Symbols);
do_type(#{kind := map, name := N, values := T}) ->
    ["{$", N, " -> ", do_type(T), "}"].
