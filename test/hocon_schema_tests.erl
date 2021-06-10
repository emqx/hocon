-module(hocon_schema_tests).

-include_lib("typerefl/include/types.hrl").
-include_lib("eunit/include/eunit.hrl").

-behaviour(hocon_schema).

-export([structs/0, fields/1]).

%% namespaces
structs() -> [bar].

fields(bar) ->
    [ {union_with_default, fun union_with_default/1}
    , {field1, fun field1/1}
    ];
fields(Other) -> demo_schema:fields(Other).

field1(type) -> string();
field1(_) -> undefined.

union_with_default(type) ->
    {union, [dummy, "priv.bool", "priv.int"]};
union_with_default(default) ->
    dummy;
union_with_default(_) -> undefined.

default_value_test() ->
    Conf = "{\"bar.field1\": \"foo\"}",
    Res = check(Conf),
    ?assertEqual(Res, check_plain(Conf)),
    ?assertEqual(#{<<"bar">> => #{ <<"union_with_default">> => dummy,
                                   <<"field1">> => "foo"}}, Res).

env_overide_test() ->
    hocon_schema:with_envs(
      fun() ->
              Conf = "{\"bar.field1\": \"foo\"}",
              Res = check(Conf),
              ?assertEqual(Res, check_plain(Conf)),
              ?assertEqual(#{<<"bar">> => #{ <<"union_with_default">> => #{<<"val">> => 111},
                                             <<"field1">> => "foo"}}, Res)
      end, [{"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"},
            {"EMQX_BAR__UNION_WITH_DEFAULT__VAL", "111"}]).

check(Str) ->
    Opts = #{format => richmap},
    {ok, RichMap} = hocon:binary(Str, Opts),
    RichMap2 = hocon_schema:check(?MODULE, RichMap),
    hocon_schema:richmap_to_map(RichMap2).

check_plain(Str) ->
    Opts = #{},
    {ok, Map} = hocon:binary(Str, Opts),
    hocon_schema:check_plain(?MODULE, Map).

mapping_test_() ->
    F = fun (Str) -> {ok, M} = hocon:binary(Str, #{format => richmap}),
                     {Mapped, _} = hocon_schema:map(demo_schema, M),
                     Mapped end,
    [ ?_assertEqual([{["person", "id"], 123}], F("person.id=123")) %% TODO: this test should fail
    , ?_assertEqual([{["app_foo", "setting"], "hello"}], F("foo.setting=hello"))
    , ?_assertEqual([{["app_foo", "setting"], "1"}], F("foo.setting=1"))
    , ?_assertThrow([{validation_error, _}], F("foo.setting=[a,b,c]"))
    , ?_assertEqual([{["app_foo", "endpoint"], {127, 0, 0, 1}}], F("foo.endpoint=\"127.0.0.1\""))
    , ?_assertThrow([{validation_error, _}], F("foo.setting=hi, foo.endpoint=hi"))
    , ?_assertThrow([{validation_error, _}], F("foo.greet=foo"))
    , ?_assertEqual([{["app_foo", "numbers"], [1, 2, 3]}], F("foo.numbers=[1,2,3]"))
    , ?_assertEqual([{["a", "b", "some_int"], 1}], F("a.b.some_int=1"))
    , ?_assertEqual([], F("foo.ref_x_y={some_int = 1}"))
    , ?_assertThrow([{validation_error, _}], F("foo.ref_x_y={some_int = aaa}"))
    , ?_assertEqual([],
        F("foo.ref_x_y={some_dur = 5s}"))
    , ?_assertEqual([{["app_foo", "refjk"], #{<<"some_int">> => 1}}],
                    F("foo.ref_j_k={some_int = 1}"))
    , ?_assertThrow([{validation_error, _},
                     {validation_error, _}], F("foo.greet=foo\n foo.endpoint=hi"))
    , ?_assertEqual([{["app_foo", "u"], #{<<"val">> => 1}}], F("b.u.val=1"))
    , ?_assertEqual([{["app_foo", "u"], #{<<"val">> => true}}], F("b.u.val=true"))
    , ?_assertThrow([{matched_no_union_member, _}], F("b.u.val=aaa"))
    , ?_assertEqual([{["app_foo", "u"], #{<<"a">> => <<"aaa">>}}],
                    F("b.u.a=aaa")) % additional field is not validated
    , ?_assertEqual([{["app_foo", "arr"], [#{<<"val">> => 1}, #{<<"val">> => 2}]}],
                    F("b.arr=[{val=1},{val=2}]"))
    , ?_assertThrow([{validation_error, _}], F("b.arr=[{val=1},{val=2},{val=a}]"))

    , ?_assertThrow([{matched_no_union_member, _}],
                    F("b.ua=[{val=1},{val=a},{val=true}]"))

    , ?_assertThrow([{matched_no_union_member, _}],
                    F("b.ua=[{val=1},{val=a9999999999999},{val=true}]"))
    , ?_assertEqual([{["app_foo", "ua"], [#{<<"val">> => 1}, #{<<"val">> => true}]}],
                    F("b.ua=[{val=1},{val=true}]"))
    ].

generate_compatibility_test() ->
    Conf = [
        {["foo", "setting"], "val"},
        {["foo", "min"], "1"},
        {["foo", "max"], "2"}
    ],

    Mappings = [
        cuttlefish_mapping:parse({mapping, "foo.setting", "app_foo.setting", [
            {datatype, string}
        ]}),
        cuttlefish_mapping:parse({mapping, "foo.min", "app_foo.range", [
            {datatype, integer}
        ]}),
        cuttlefish_mapping:parse({mapping, "foo.max", "app_foo.range", [
            {datatype, integer}
        ]})
    ],

    MinMax = fun(C) ->
        Min = cuttlefish:conf_get("foo.min", C),
        Max = cuttlefish:conf_get("foo.max", C),
        case Min < Max of
            true ->
                {Min, Max};
            _ ->
                throw("should be min < max")
        end end,

    Translations = [
        cuttlefish_translation:parse({translation, "app_foo.range", MinMax})
    ],

    {ok, Hocon} = hocon:binary("foo.setting=val,foo.min=1,foo.max=2",
                               #{format => richmap}),

    [{app_foo, C0}] = cuttlefish_generator:map({Translations, Mappings, []}, Conf),
    [{app_foo, C1}] = hocon_schema:generate(demo_schema, Hocon),
    ?assertEqual(lists:ukeysort(1, C0), lists:ukeysort(1, C1)).

atom_key_test() ->
    Sc = #{structs => [''],
          fields => [{val, binary()}]
        },
    ?assertEqual(#{val => <<"a">>},
                 hocon_schema:check(Sc, #{<<"val">> => <<"a">>}), #{atom_key => true}),
    ?assertEqual(#{<<"val">> => <<"a">>},
                 hocon_schema:check(Sc, #{<<"val">> => <<"a">>})).
