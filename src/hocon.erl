%%--------------------------------------------------------------------
%% Copyright (c) 2020 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon).

-export([load/1, load/2, scan/1, parse/1, dump/2, dump/3]).
-export([main/1]).

-type config() :: map().
-type ctx() :: map().

-export_type([config/0]).

main(Args) ->
    hocon_cli:main(Args).

-spec(load(file:filename()) -> {ok, config()} | {error, term()}).
load(Filename) ->
    load(Filename, #{}).

load(Filename0, Ctx0) ->
    Filename = filename:absname(Filename0),
    Ctx = inc_stack_push(Ctx0, Filename),
    pipeline(Filename, Ctx,
             [ fun read/1
             , fun scan/1
             , fun parse/1
             , fun expand/1
             , fun transform/2
             ]).

dump(Config, App) ->
    [{App, to_list(Config)}].

dump(Config, App, Filename) ->
    file:write_file(Filename, io_lib:fwrite("~p.\n", [dump(Config, App)])).

to_list(Config) when is_map(Config) ->
    maps:to_list(maps:map(fun(_Key, MVal) -> to_list(MVal) end, Config));
to_list(Value) -> Value.

-spec(read(file:filename()) -> {ok, binary()} | {error, term()}).
read(Filename) ->
    case file:read_file(Filename) of
        {ok, <<239, 187, 191, Rest/binary>>} ->
            %% Ignore BOM header
            {ok, Rest};
        {ok, Bytes} ->
            {ok, Bytes};
        {error, Reason} ->
            {error, Reason}
    end.

-spec(scan(binary()|string()) -> {ok, config()} | {error, Reason}
     when Reason :: {scan_error, string()}).
scan(Input) when is_binary(Input) ->
    scan(binary_to_list(Input));
scan(Input) when is_list(Input) ->
    case hocon_scanner:string(Input) of
        {ok, Tokens, _EndLine} -> {ok, Tokens};
        {error, {Line, _Mod, ErrorInfo}, _} ->
            scan_error(Line, hocon_scanner:format_error(ErrorInfo))
    end.

-spec(parse(list()) -> {ok, config()} | {error, Reason}
      when Reason :: {parse_error, string()}).
parse([]) -> {ok, []};
parse(Tokens) ->
    case hocon_parser:parse(Tokens) of
        {ok, Ret} -> {ok, Ret};
        {error, {Line, _Module, ErrorInfo}} ->
            parse_error(Line, ErrorInfo)
    end.

-spec(transform(config(), ctx()) -> {ok, config()}).
transform(Config, Ctx) ->
    try include(substitute(Config), Ctx) of
        RootMap -> {ok, RootMap}
    catch
        error:Reason:St -> {error, {Reason,St}}
    end.

include(RootMap, Ctx) ->
    maps:fold(fun('$include', File, Acc) ->
                      include(binary_to_list(File), Ctx, Acc);
                 (Key, MVal, Acc) when is_map(MVal) ->
                      Acc#{Key => include(MVal, Ctx)};
                 (Key, Val, Acc) ->
                      Acc#{Key => Val}
              end, #{}, RootMap).

include(File0, Ctx, Map) ->
    %% File0 is the name given in the 'include' literal
    Stack = inc_stack(Ctx),
    Cwd = filename:dirname(hd(Stack)),
    %% Cwd is abs path, if File0 is also abs, filename:join returns File0
    File = filename:join([Cwd, File0]),
    case is_included(Ctx, File) of
        true ->
            error({include_error, File0, {cycle, Stack}});
        false ->
            do_include(File, Ctx, Map)
    end.

do_include(File, Ctx, Map) ->
    case load(File, Ctx) of
        {ok, MConf} ->
            maps:merge(MConf, Map);
        {error, Reason} ->
            error({include_error, File, Reason})
    end.

substitute(RootMap) ->
    substitute(RootMap, RootMap).

substitute(MapVal, RootMap) when is_map(MapVal) ->
    maps:map(fun(_Key, Substrings) -> substitute(Substrings, RootMap) end, MapVal);
substitute({concat, Substrings}, RootMap) ->
    iolist_to_binary(lists:map(fun(S) -> substitute(S, RootMap) end, Substrings));
substitute({var, Name}, RootMap) ->
    do_substitute(Name, RootMap);
substitute(Value, _RootMap) -> Value.

do_substitute(Varname, RootMap) ->
    case nested_get(paths(Varname), RootMap) of
        undefined -> error({variable_not_found, Varname});
        Val -> substitute(Val, RootMap)
    end.

expand({Members}) ->
    expand(Members);
expand(Members) when is_list(Members) ->
    expand(Members, #{}).

expand([], Map) -> Map;
expand([{Key, Value}|More], Map) ->
    expand(More, nested_put(paths(Key), expand_value(Value), Map)).

expand_value({Members}) ->
    expand(Members);
expand_value(Array) when is_list(Array) ->
    [expand_value(Val) || Val <- Array];
expand_value(Literal) -> Literal.

paths(Key) when is_atom(Key) ->
    paths(atom_to_list(Key));
paths(Key) when is_binary(Key) ->
    paths(binary_to_list(Key));
paths(Key) when is_list(Key) ->
    lists:map(fun list_to_atom/1, string:tokens(Key, ".")).

nested_put([Key], Val, Map) ->
    merge(Key, Val, Map);
nested_put([Key|Paths], Val, Map) ->
    merge(Key, nested_put(Paths, Val, #{}), Map).

merge(Key, Val, Map) when is_map(Val) ->
    case maps:find(Key, Map) of
        {ok, MVal} when is_map(MVal) ->
            maps:put(Key, maps:merge(MVal, Val), Map);
        _Other -> maps:put(Key, Val, Map)
    end;
merge(Key, Val, Map) -> maps:put(Key, Val, Map).

nested_get(Key, Map) ->
    nested_get(Key, Map, undefined).

nested_get([Key], Map, Default) ->
    maps:get(Key, Map, Default);
nested_get([Key|More], Map, Default) ->
    case maps:find(Key, Map) of
        {ok, MVal} when is_map(MVal) ->
            nested_get(More, MVal, Default);
        {ok, _Val} -> Default;
        error -> Default
    end.

pipeline(Input, Ctx, [Fun | Steps]) ->
    Result = case is_function(Fun, 1) of
                 true -> Fun(Input);
                 false -> Fun(Input, Ctx)
             end,
    case Result of
        {ok, Output} -> pipeline(Output, Ctx, Steps);
        {error, Reason} -> {error, Reason};
        Output -> pipeline(Output, Ctx, Steps)
    end;
pipeline(Output, _Ctx, []) -> {ok, Output}.

scan_error(Line, ErrorInfo) ->
    {error, {scan_error, format_error(Line, ErrorInfo)}}.

parse_error(Line, ErrorInfo) ->
    {error, {parse_error, format_error(Line, ErrorInfo)}}.

format_error(Line, ErrorInfo) ->
    binary_to_list(
      iolist_to_binary(
        [ErrorInfo, io_lib:format(" in line ~w", [Line])])).

inc_stack_push(Ctx, File) ->
    Includes = inc_stack(Ctx),
    Ctx#{stack => [File | Includes]}.

is_included(Ctx, File) ->
    Includes = inc_stack(Ctx),
    lists:any(fun(F) -> is_same_file(F, File) end, Includes).

inc_stack(Ctx) -> maps:get(stack, Ctx, []).

is_same_file(A, B) ->
    real_file_name(A) =:= real_file_name(B).

real_file_name(F) ->
    case file:read_link_all(F) of
        {ok, Real} -> Real;
        {error, _} -> F
    end.
