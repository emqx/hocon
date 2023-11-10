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

-ifndef(HOCONSC_TYPES_HRL).
-define(HOCONSC_TYPES_HRL, true).

-define(ARRAY(OfTYpe), {array, OfTYpe}).
-define(UNION(OfTypes), {union, OfTypes, undefined}).
-define(UNION(OfTypes, DisplayName), {union, OfTypes, DisplayName}).
-define(ENUM(OfSymbols), {enum, OfSymbols}).
-define(REF(Name), {ref, Name}).
% remote ref
-define(R_REF(Module, Name), {ref, Module, Name}).
-define(R_REF(NAME), ?R_REF(?MODULE, NAME)).
-define(IS_TYPEREFL(X), (is_tuple(X) andalso element(1, Type) =:= '$type_refl')).

%% A field having lazy type is not type-checked as a part of its enclosing struct
%% the user of this field is responsible for type checks at runtime
%% the hint type is useful when generating documents
-define(LAZY(HintType), {lazy, HintType}).

%% Map keys are always strings
-define(MAP(Name, Type), {map, Name, Type}).

%% A description namespace does not have to be the type namespace
%% but would be good to have an alignment
-define(DESC(Namespace, Id), {desc, Namespace, Id}).
%% NOTE: Using module for namespace
%% results in very clear mapping between types and descriptions.
%% However it is perhaps not quite friendly for translators
%% when need to support multiple languages.
-define(DESC(Id), ?DESC(?MODULE, Id)).

%% To avoid not import those function. we provide a macro to call them.
-define(HOCON(Type), hoconsc:mk(Type)).
-define(HOCON(Type, Meta), hoconsc:mk(Type, Meta)).

-endif.
