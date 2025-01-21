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

%% This header file is intended for internal use in parser modules.

-ifndef(HOCON_HRL).
-define(HOCON_HRL, true).

-define(COMPUTED, '_computed').

-define(IS_VALUE_LIST(T), (T =:= array orelse T =:= concat orelse T =:= object)).
-define(IS_FIELD(F), (is_tuple(F) andalso size(F) =:= 2)).

-define(SECOND, 1000).
-define(MINUTE, (?SECOND * 60)).
-define(HOUR, (?MINUTE * 60)).
-define(DAY, (?HOUR * 24)).
-define(WEEK, (?DAY * 7)).
-define(FORTNIGHT, (?WEEK * 2)).

-define(KILOBYTE, 1024).
%1048576
-define(MEGABYTE, (?KILOBYTE * 1024)).
%1073741824
-define(GIGABYTE, (?MEGABYTE * 1024)).

-endif.
