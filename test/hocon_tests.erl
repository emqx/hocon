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

-module(hocon_tests).

-include_lib("eunit/include/eunit.hrl").

%% try to load all sample files
%% expect no crash
sample_files_test_() ->
    Wildcard = filename:join([code:lib_dir(hocon), "sample-configs", "*.conf"]),
    [begin
        BaseName = filename:basename(F, ".conf"),
        {BaseName, fun() -> test_file_load(BaseName, F) end}
     end || F <- filelib:wildcard(Wildcard)].

test_file_load("cycle"++_, F) ->
    ?assertMatch({error, {{include_error, _, _}, _}}, hocon:load(F));
test_file_load("test13-reference-bad-substitutions", F) ->
    ?assertMatch({error, {{variable_not_found,"b"}, _}}, hocon:load(F));
test_file_load(_Name, F) ->
    ?assertMatch({ok, _}, hocon:load(F)).

