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

-export([load/1, parse/1]).

-type(config() :: proplists:proplist()).

-export_type([config/0]).

-spec(load(file:filename()) -> {ok, config()} | {error, term()}).
load(Filename) ->
    case file:read_file(Filename) of
        {ok, Config} ->
            parse(Config);
        Error -> Error
    end.

-spec(parse(binary()|string()) -> {ok, config()} | {error, Reason}
      when Reason :: {scan_error | parse_error, string()}).
parse(Input) when is_binary(Input) ->
    parse(binary_to_list(Input));

parse(Input) when is_list(Input) ->
    case hocon_scanner:string(Input) of
        {ok, Tokens, _EndLine} ->
            do_parse(Tokens);
        {error, {Line, _Mod, ErrorInfo}, _} ->
            ErrorInfo1 = hocon_scanner:format_error(ErrorInfo),
            {error, {scan_error, format_error(ErrorInfo1, Line)}}
    end.

do_parse(Tokens) ->
    case hocon_parser:parse(Tokens) of
        {ok, Ret} -> {ok, Ret};
        {error, {Line, _Module, ErrorInfo}} ->
            {error, {parse_error, format_error(ErrorInfo, Line)}}
    end.

format_error(ErrorInfo, Line) ->
    binary_to_list(
      iolist_to_binary(
        [ErrorInfo, io_lib:format(" in line ~w", [Line])])).

%% Pipeline: read, scan, parse, apply, maybe setenv or dump to app.config

%% Apply:
%% - ability to refer to another part of the configuration (set a value to another value)
%% - import/include another configuration file into the current file
%% - a mapping to a flat properties list such as Java's system properties
%% - ability to get values from environment variables



