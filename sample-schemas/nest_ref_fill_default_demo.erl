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

-module(nest_ref_fill_default_demo).
-include_lib("typerefl/include/types.hrl").
-include("hoconsc.hrl").
-behaviour(hocon_schema).

-export([namespace/0, roots/0, fields/1]).

namespace() -> ?MODULE.

roots() ->
  ["broker"].

fields("broker") ->
  [{"route_batch_clean",
    hoconsc:mk(boolean(), #{default => true}
    )},
    {"perf", hoconsc:mk(
      hoconsc:ref(?MODULE, "broker_perf"),
      #{importance => ?IMPORTANCE_HIDDEN})}
  ];
fields("broker_perf") ->
  [
    {"route_lock_type",
      hoconsc:mk(
        hoconsc:enum([key, tab, global]),
        #{
          default => key
        }
      )},
    {"trie_compaction",
      hoconsc:mk(
        boolean(),
        #{
          default => true
        }
      )}
  ].
