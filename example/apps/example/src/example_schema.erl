-module(example_schema).

-export([roots/0, fields/1]).

roots() -> [myserver].

fields(myserver) ->
    [ {listeners,
       hoconsc:mk(
            hoconsc:map(name,
                        hoconsc:union([hoconsc:ref(http_listener),
                                       hoconsc:ref(https_listener)])),
            #{mapping => "example.listeners"})
      }
    , {concurrent_users_limit, typerefl:integer()}
    ];
fields(http_listener) ->
    [ {port, typerefl:integer()}
    ];
fields(https_listener) ->
    [ {port, typerefl:integer()}
    , {ssl, {ref, ssl}}
    ];
fields(ssl) ->
    [ {cacertfile, typerefl:string()}
    , {keyfile, typerefl:string()}
    , {certfile, typerefl:string()}
    ].
