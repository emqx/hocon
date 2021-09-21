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

-module(hocon_schema_html).

-export([gen/2]).

-include("hoconsc.hrl").
-include("hocon_private.hrl").

gen(Schema, Title) ->
    {RootNs, RootFields, Structs} = hocon_schema:find_structs(Schema),
    IndexHtml = fmt_index(RootFields, Structs),
    StructsHtml =
        [fmt_structs(1, RootNs, [{RootNs, "Root Keys", RootFields}]),
         fmt_structs(2, RootNs, Structs)],
    render([{<<"%%MAGIC_CHICKEN_TITLE%%">>, Title},
            {<<"%%MAGIC_CHICKEN_INDEX%%">>, IndexHtml},
            {<<"%%MAGIC_CHICKEN_STRUCTS%%">>, StructsHtml}
           ]).

fmt_structs(_Weight, _RootNs, []) -> [];
fmt_structs(Weight, RootNs, [{Ns, Name, Fields} | Rest]) ->
    [fmt_struct(Weight, RootNs, Ns, Name, Fields), "\n" |
     fmt_structs(Weight, RootNs, Rest)].

fmt_struct(Weight, RootNs, Ns0, Name, Fields) ->
    Ns = case RootNs =:= Ns0 of
             true -> undefined;
             false -> Ns0
         end,
    FieldsHtml= ul(fmt_fields(Weight + 1, Ns, Fields)),
    FullNameDisplay = ref(Ns, Name),
    [html_hd(Weight, FullNameDisplay), FieldsHtml].

html_hd(Weight, StructName) ->
    H = ["<h", integer_to_list(Weight), ">"],
    E = ["</h", integer_to_list(Weight), ">"],
    [H, local_anchor(StructName), E, "\n"].

fmt_fields(_Weight, _Ns, []) -> [];
fmt_fields(Weight, Ns, [{Name, FieldSchema} | Fields]) ->
    Type = fmt_type(Ns, hocon_schema:field_schema(FieldSchema, type)),
    Default = fmt_default(hocon_schema:field_schema(FieldSchema, default)),
    Desc = hocon_schema:field_schema(FieldSchema, desc),
    HTML =
        li([ ["<p class=\"fn\">", bin(Name), "</p>\n"]
           , case Desc =/= undefined of
                 true -> html_div("desc", Desc);
                 false -> []
             end
           , html_div("desc", [em("type:"), Type])
           , case Default =/= undefined of
                 true  -> html_div("desc", [em("default:"), Default]);
                 false -> []
             end
           ]),
    [bin(HTML) | fmt_fields(Weight, Ns, Fields)].

em(X) -> ["<em>", X, "</em>"].

fmt_default(undefined) -> undefined;
fmt_default(Value) ->
    pre(hocon_pp:do(Value, #{newline => "\n", embedded => true})).

fmt_type(Ns, T) -> pre(do_type(Ns, T)).

do_type(_Ns, A) when is_atom(A) -> bin(A); % singleton
do_type(Ns, Ref) when is_list(Ref) -> do_type(Ns, ?REF(Ref));
do_type(Ns, ?REF(Ref)) -> local_href(ref(Ns, Ref));
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

render(Substs) ->
    %% load app to access priv dir
    case application:load(hocon) of
        ok -> ok;
        {error, {already_loaded, _}} -> ok
    end,
    PrivDir = code:priv_dir(hocon),
    Template = filename:join([PrivDir, "doc-template.html"]),
    case file:read_file(Template) of
        {ok, Bin} -> render(Substs, Bin);
        {error, X} -> exit({X, Template})
    end.

%% poorman's template
render([], Bin) -> Bin;
render([{Pattern, Value} | Rest], Bin) ->
    [H, T] = binary:split(Bin, Pattern),
    render(Rest, bin([H, Value, T])).

fmt_index(RootFields, Structs) ->
    [html_div(ul([li(local_href("Root Keys", bin(Name))) || {Name, _} <- RootFields])),
     "<hr/>\n",
     html_div(ul([li(local_href(ref(Ns, Name))) || {Ns, Name, _} <- Structs]))
    ].

html_div(X) -> ["<div>", X, "</div>\n"].

html_div(Class, X) -> ["<div class=\"", Class, "\">\n", X, "</div>\n"].

ul(X) -> ["<ul>\n", X, "</ul>\n"].

li(X) -> ["<li>", X, "</li>\n"].

local_anchor(Anchor) ->
    do_anchor("name", Anchor, Anchor).

local_href(Anchor) ->
    local_href(Anchor, Anchor).

local_href(Anchor, Display) ->
    do_anchor("href", bin(["#", bin(Anchor)]), Display).

do_anchor(Tag, Ref, Display) ->
    ["<a ", Tag, "=\"", anchor(Ref), "\">", bin(Display), "</a>"].

pre(Code) -> ["\n<pre>\n", Code, "\n</pre>\n"].

anchor(Anchor0) ->
    Anchor = string:lowercase(bin(Anchor0)),
    Replaces = [{<<"\\.">>, <<"">>}, %% no dot
                {<<"'">>, <<"">>}, %% no single quotes
                {<<":">>, <<"">>}, %% no colon
                {<<"\\s">>, <<"-">>} %% space replaced by hyphen
               ],
    lists:foldl(fun({Pattern, Replace}, Acc) ->
                        re:replace(Acc, Pattern, Replace,
                                   [{return, list}, global])
                end, Anchor, Replaces).
