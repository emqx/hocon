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

-module(hocon_schema_md_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("typerefl/include/types.hrl").

no_crash_test_() ->
    [{"demo_schema", gen(demo_schema, "./test/data/demo_schema_doc.conf")},
     {"demo_schema2", gen(demo_schema2)},
     {"demo_schema3", gen(demo_schema3)},
     {"emqx_schema", gen(emqx_schema)},
     {"arbitrary1", gen(#{namespace => dummy,
                          roots => [foo],
                          fields => #{foo => [{"f1", hoconsc:enum([bar])}]}
                         })},
     {"arbitrary2",
      gen(#{namespace => dummy,
            roots => [foo],
            fields => #{foo => [{"f1", hoconsc:mk(hoconsc:ref(emqx_schema, "zone"))}]}
           })},
     {"multi-line-default",
      gen(#{ namespace => "rootns"
           , roots => [foo]
           , fields => #{foo => [{"f1", hoconsc:mk(hoconsc:ref(emqx_schema, "etcd"),
                                                   #{default => #{<<"server">> => <<"localhost">>,
                                                                  <<"prefix">> => <<"prefix">>,
                                                                  <<"node_ttl">> => "100s",
                                                                  <<"ssl">> => <<>>
                                                                 }})}]}
           })}
    ].

gen(Schema) -> fun() -> hocon_schema_md:gen(Schema, "test") end.
gen(Schema, DescFile) -> fun() -> hocon_schema_md:gen(Schema,
  #{title => "test", body => <<>>, desc_file => DescFile}) end.

find_structs_test() ->
    {demo_schema3, _Roots, Subs} = hocon_schema:find_structs(demo_schema3),
    Find = fun(N) -> is_tuple(lists:keyfind(N, 2, Subs)) end,
    ?assert(Find(bar)),
    ?assert(Find(foo)),
    ?assert(Find(parent)),
    ?assert(Find("sub1")),
    ?assert(Find("sub2")).
