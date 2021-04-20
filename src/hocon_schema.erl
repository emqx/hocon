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

-module(hocon_schema).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([map/2]).

map(Proplist, Schema) ->
    [do_map(KV, Schema) || KV <- Proplist].

do_map({Key, Value}, Schema) ->
    Type = get(Key, type, Schema),
    Value0 = convert(Value, Type),
    Validators = get(Key, validators, Schema),
    ok = validate(Value0, Validators),
    MapTo = string:tokens(get(Key, map_to, Schema), "."),
    {MapTo, Value0}.

convert(Value, ip) ->
    case inet:parse_address(Value) of
        {ok, Addr} ->
            Addr;
        {error, Reason} ->
            throw(Reason)
    end;
convert(Value, _) ->
    Value.

validate(_, []) ->
    ok;
validate(_, undefined) ->
    ok;
validate(Value, [H | T]) ->
    case H(Value) of
        true ->
            validate(Value, T);
        false ->
            throw({validate, H})
    end;
validate(Value, SingleValidator) ->
    validate(Value, [SingleValidator]).

get(Key, Param, Schema) ->
    Keys = apply(Schema, keys, []),
    apply(proplists:get_value(string:join(Key, "."), Keys), [Param]).

-ifdef(TEST).

basic_test() ->
    Config0 = [ {["foo", "setting"], "hello"}, {["foo", "endpoint"], "127.0.0.1"}],
    ?assertEqual([{["app_foo", "setting"], "hello"},
                  {["app_foo", "endpoint"], {127, 0, 0, 1}}], map(Config0, demo_schema)),
    Config1 = [{["foo", "setting"], "xxxxxxxxxxxxxxxxxxxxxx"}],
    ?assertThrow(_, map(Config1, demo_schema)),
    Config2 = [{["foo", "endpoint"], "notip"}],
    ?assertThrow(_, map(Config2, demo_schema)).

-endif.
