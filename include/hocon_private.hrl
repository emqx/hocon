%%--------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-ifndef(HOCON_PRIVATE_HRL).
-define(HOCON_PRIVATE_HRL, true).

-define(METADATA, '$hcMeta').
-define(HOCON_V, '$hcVal').
-define(HOCON_T, '$hcTyp').

%% random magic bytes to work as newline instead of "\n"
-define(NL, <<"magic-chicken", 255, 156, 173, 82, 187, 168, 136>>).
-endif.
