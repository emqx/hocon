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

-ifndef(HOCONSC_HRL).
-define(HOCONSC_HRL, true).

-include_lib("typerefl/include/types.hrl").
-include_lib("hocon/include/hocon_types.hrl").

%% high importance, should be visible to all users
-define(IMPORTANCE_HIGH, high).
%% medium important, should be visible to most users
-define(IMPORTANCE_MEDIUM, medium).
%% not important, usually only for advanced users
-define(IMPORTANCE_LOW, low).
%% hidden from documentation, but still returned by HTTP APIs and raw config
-define(IMPORTANCE_NO_DOC, no_doc).
%% hidden for normal users, only experts should need to care
-define(IMPORTANCE_HIDDEN, hidden).

%% The default importance level for a config item.
-define(DEFAULT_IMPORTANCE, ?IMPORTANCE_HIGH).
%% The default minimum importance level when dumping config schema
%% or filling config default values.
-define(DEFAULT_INCLUDE_IMPORTANCE_UP_FROM, ?IMPORTANCE_NO_DOC).

-endif.
