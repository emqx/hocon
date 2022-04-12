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

-module(hocon_schema_html_tests).

-include_lib("eunit/include/eunit.hrl").

no_crash_test_() ->
    [{"demo_schema", gen(demo_schema, "./test/data/demo_schema_doc.conf")},
     {"demo_schema2", gen(demo_schema2)},
     {"emqx_schema", gen(emqx_schema)},
     {"arbitrary1", gen(#{namespace => dummy,
                          roots => [foo],
                          fields => #{foo => [{"f1", hoconsc:enum([bar])}]}
                         })},
     {"arbitrary2",
      gen(#{namespace => dummy,
            roots => [foo],
            fields => #{foo => [{"f1", hoconsc:mk(hoconsc:ref(emqx_schema, "zone"))}]}
           })}
    ].

gen(Schema) -> fun() -> hocon_schema_html:gen(Schema, "test", undefined) end.
gen(Schema, DescFile) -> fun() -> hocon_schema_html:gen(Schema, "test", DescFile) end.
