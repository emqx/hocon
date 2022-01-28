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

-module(hocon_schema_md).

-export([gen/2]).

-include("hoconsc.hrl").
-include("hocon_private.hrl").

gen(Schema, undefined) ->
    gen(Schema, "# HOCON Document");
gen(Schema, Title) when is_list(Title) orelse is_binary(Title) ->
    gen(Schema, #{title => Title, body => <<>>});
gen(Schema, #{title := Title, body := Body}) ->
    {RootNs, RootFields, Structs} = hocon_schema:find_structs(Schema),
    [Title,
     "\n",
     Body,
     "\n",
     fmt_structs(2, RootNs, [{RootNs, "Root Config Keys", #{fields => RootFields}}]),
     fmt_structs(2, RootNs, Structs)].

fmt_structs(_Weight, _RootNs, []) -> [];
fmt_structs(Weight, RootNs, [{Ns, Name, Fields} | Rest]) ->
    [fmt_struct(Weight, RootNs, Ns, Name, Fields), "\n" |
     fmt_structs(Weight, RootNs, Rest)].

fmt_struct(Weight, RootNs, Ns0, Name, #{fields := Fields} = Meta) ->
    Ns = case RootNs =:= Ns0 of
             true -> undefined;
             false -> Ns0
         end,
    Paths = case Meta of
                #{paths := Ps} -> lists:sort(maps:keys(Ps));
                _ -> []
            end,
    FullNameDisplay = ref(Ns, Name),
    [ hocon_md:h(Weight, FullNameDisplay)
    , fmt_paths(Paths)
    , case Meta of
          #{desc := StructDoc} -> StructDoc;
          _ -> []
      end
    , "\n**Fields**\n\n"
    , fmt_fields(Ns, Fields)
    ].

fmt_paths([]) -> [];
fmt_paths(Paths) ->
    Envs = lists:map(fun(Path0) ->
                              Path = string:tokens(Path0, "."),
                              Env = string:uppercase(string:join(Path, "__")),
                              hocon_util:env_prefix("EMQX_") ++ Env
                      end, Paths),
    ["\n**Config paths**\n\n",
     simple_list(Paths),
     "\n"
     "\n**Env overrides**\n\n",
     simple_list(Envs),
     "\n"
    ].

simple_list(L) ->
    [[" - ", hocon_md:code(I), "\n"] || I <- L].

fmt_fields(_Ns, []) -> [];
fmt_fields(Ns, [{Name, FieldSchema} | Fields]) ->
    case hocon_schema:field_schema(FieldSchema, hidden) of
        true -> fmt_fields(Ns, Fields);
        _ -> [bin(fmt_field(Ns, Name, FieldSchema)) | fmt_fields(Ns, Fields)]
    end.

fmt_field(Ns, Name, FieldSchema) ->
    Type = fmt_type(Ns, hocon_schema:field_schema(FieldSchema, type)),
    Default = fmt_default(hocon_schema:field_schema(FieldSchema, default)),
    Desc = hocon_schema:field_schema(FieldSchema, desc),
    [ ["- ", bin(Name), ": ", Type, "\n"]
    , case Default =/= undefined of
          true  -> ["\n", hocon_md:indent(2, [["Default = ", Default]]), "\n"];
          false -> []
      end
    , case Desc =/= undefined of
          true -> ["\n", hocon_md:indent(2, [Desc]), "\n"];
          false -> []
      end
    , "\n"
    ].

fmt_default(undefined) -> undefined;
fmt_default(Value) ->
    case hocon_pp:do(Value, #{newline => "", embedded => true}) of
        [OneLine] -> ["`", OneLine, "`"];
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
do_type(Ns, ?MAP(Name, T)) -> ["{$", bin(Name), " -> ", do_type(Ns, T), "}"];
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

bin(S) when is_list(S) -> unicode:characters_to_binary(S, utf8);
bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(B) when is_binary(B) -> B.
