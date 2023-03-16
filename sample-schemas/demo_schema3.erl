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

-module(demo_schema3).
-include_lib("typerefl/include/types.hrl").
-behaviour(hocon_schema).

-export([namespace/0, roots/0, fields/1, tags/0]).

namespace() -> ?MODULE.

tags() ->
    [<<"tag1">>, <<"another tag">>].

roots() ->
    [ {foo, hoconsc:array(hoconsc:ref(foo))}
    , {bar, hoconsc:ref(parent)}
    ].

fields(foo) ->
    [ {bar, hoconsc:ref(bar)}
    ];
fields(bar) ->
    Sc = hoconsc:union([hoconsc:ref(foo), null]), %% cyclic refs
    [{"baz", Sc}];
%% below fields are to cover the test where identical paths for the same name
%% i.e. bar.f1.subf.baz can be reached from both "sub1" and "sub2"
fields(parent) ->
    [{"f1", hoconsc:union([hoconsc:ref("sub1"), hoconsc:ref("sub2")])}];
fields("sub1") ->
    [{"sub_f", hoconsc:ref(bar)}]; %% both sub1 and sub2 refs to bar
fields("sub2") ->
    [{"sub_f", hoconsc:ref(bar)}]. %% both sub1 and sub2 refs to bar
