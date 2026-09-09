%%--------------------------------------------------------------------
%% Copyright (c) 2026 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(hocon_cli_mixed_union_schema).

-behaviour(hocon_schema).

-include_lib("typerefl/include/types.hrl").

-export([namespace/0, roots/0, fields/1]).

namespace() -> undefined.

roots() ->
    [
        {integer_or_node, hoconsc:union([integer(), hoconsc:ref(node)])},
        {ip_or_node,
            hoconsc:mk(
                hoconsc:union([typerefl:ip4_address(), hoconsc:ref(node)]),
                #{converter => fun convert_ip_or_node/2}
            )},
        {array_or_string_node, hoconsc:union([hoconsc:ref(array_node), hoconsc:ref(string_node)])}
    ].

fields(node) ->
    [{value, string()}];
fields(array_node) ->
    [{value, hoconsc:mk(hoconsc:array(integer()), #{required => true})}];
fields(string_node) ->
    [{value, hoconsc:mk(string(), #{default => "hello"})}].

convert_ip_or_node(<<"127.0.0.1">>, _Opts) ->
    {127, 0, 0, 1};
convert_ip_or_node(#{<<"legacy_value">> := Value}, _Opts) ->
    #{<<"value">> => Value};
convert_ip_or_node(Value, _Opts) ->
    Value.
