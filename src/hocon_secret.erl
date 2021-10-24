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

%% @doc NOTE: Do not modify this module between releases which hot-beam.
%% upgrade is intended.
%% The idea is to make the anonymous function holding a secret long-lived
%% even stored in ets table or persistent term without having to worry
%% about it becoming a badfun after a hot-beam upgrade.
-module(hocon_secret).

-export([hide/1, peek/1, is/1]).
-export_type([hidden/0]).

-opaque hidden() :: {?MODULE, function()}.

%% @doc Hides the secret in an anonymous function, the nature of Erlang
%% closure makes it impossible to serialize the enclosing vairables to
%% plaintext.
%% NOTE: `undefined' is not a secret.
hide(undefined) -> undefined;
hide({?MODULE, F}) -> {?MODULE, F};
hide(Secret) -> {?MODULE, fun() -> Secret end}.

%% @doc Tries to peek a hidden secret.
peek({?MODULE, F}) when is_function(F, 0) -> F();
peek(Other) -> Other.

%% @doc Return true if it is a secret.
is({?MODULE, F}) when is_function(F, 0) -> true;
is(_) -> false.
