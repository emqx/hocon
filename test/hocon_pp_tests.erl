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
-module(hocon_pp_tests).

-include_lib("erlymatch/include/erlymatch.hrl").
-include_lib("typerefl/include/types.hrl").
-include_lib("eunit/include/eunit.hrl").

atom_test() ->
    RawConf =
        #{
            atom_key => #{atom_key => atom_value},
            <<"binary_key">> => #{
                atom_key1 => <<"binary_value">>,
                atom_key2 => '42wierd_atom_value',
                atom_key3 => ''
            }
        },
    PP = hocon_pp:do(RawConf, #{}),
    {ok, RawConf2} = hocon:binary(iolist_to_binary(PP)),
    ?assertEqual(
        #{
            <<"atom_key">> => #{<<"atom_key">> => <<"atom_value">>},
            <<"binary_key">> => #{
                <<"atom_key1">> => <<"binary_value">>,
                <<"atom_key2">> => <<"42wierd_atom_value">>,
                <<"atom_key3">> => <<"">>
            }
        },
        RawConf2
    ).

pp_test_() ->
    [
        {"emqx.conf", do_fun("etc/emqx.conf")},
        {"null.conf", do_fun("etc/null.conf")},
        {"unicode.conf", do_fun("etc/unicode.conf")},
        {"unescape.conf", do_fun("etc/unescape.conf")},
        {"map_with_placeholders.conf", do_fun("etc/map_with_placeholders.conf")}
    ].

do_fun(File) ->
    fun() -> do(File) end.

do(File) ->
    {ok, Conf} = hocon:load(File),
    PP = hocon_pp:do(Conf, #{}),
    {ok, Conf2} = hocon:binary(iolist_to_binary(PP)),
    ?assertEqual(Conf, Conf2),
    TmpFile = File ++ ".pp",
    file:write_file(TmpFile, [PP]),
    {ok, Conf3} = hocon:load(TmpFile),
    ?assertEqual(Conf, Conf3),
    file:delete(TmpFile).

pp_escape_to_file_test() ->
    File = "etc/unescape.conf",
    {ok, Conf} = hocon:load(File),
    PP = hocon_pp:do(Conf, #{}),
    TmpFile = File ++ ".pp",
    file:write_file(TmpFile, [PP]),
    ?assertEqual(file:read_file(File), file:read_file(TmpFile)),
    file:delete(TmpFile),
    ok.

pp_quote_test() ->
    Fun = fun(Map, ExpectBin) ->
        Bin = iolist_to_binary(hocon_pp:do(Map, #{})),
        ?assertEqual(ExpectBin, Bin),
        {ok, Map2} = hocon:binary(Bin),
        ?assertEqual(Map, Map2)
    end,
    %% normal without quote
    Fun(#{<<"d_dfdk2f">> => <<"19%">>}, <<"d_dfdk2f = 19%\n">>),
    %% key begin with integer should be quote
    Fun(#{<<"1f">> => <<"1d">>}, <<"\"1f\" = 1d\n">>),
    %% key begin with _ should be quote
    Fun(#{<<"_f">> => 12}, <<"\"_f\" = 12\n">>),
    %% value contain special char should be quote
    Fun(#{<<"d2">> => <<"_kdfj">>}, <<"d2 = \"_kdfj\"\n">>),
    Fun(#{<<"d_dfdk2f">> => <<"https://test.com">>}, <<"d_dfdk2f = \"https://test.com\"\n">>),
    %% value is empty string should be quote
    Fun(#{<<"d_dfdk2f">> => <<>>}, <<"d_dfdk2f = \"\"\n">>),
    Fun(
        #{<<"d_dfdk2f">> => <<"466f5fbb86b19f14f921784539870228">>},
        <<"d_dfdk2f = \"466f5fbb86b19f14f921784539870228\"\n">>
    ),
    Fun(#{<<"$d_dfdk2f">> => <<"12">>}, <<"\"$d_dfdk2f\" = \"12\"\n">>),

    %% backslash
    Fun(#{<<"test_backslash">> => <<"\\emqx">>}, <<"test_backslash = \"\\\\emqx\"\n">>),
    Fun(#{<<"test_backslash">> => <<"emqx\\emqx">>}, <<"test_backslash = \"emqx\\\\emqx\"\n">>),
    Fun(#{<<"test_backslash">> => <<"emqx\\">>}, <<"test_backslash = \"emqx\\\\\"\n">>),

    %% quote
    Fun(#{<<"test_quote">> => <<"\"emqx">>}, <<"test_quote = \"\\\"emqx\"\n">>),
    Fun(#{<<"test_quote">> => <<"emqx\"emqx">>}, <<"test_quote = \"emqx\\\"emqx\"\n">>),
    Fun(#{<<"test_quote">> => <<"emqx\"">>}, <<"test_quote = \"emqx\\\"\"\n">>),

    %% '${}[]:=,+#`^?!@*& ' should quote
    lists:foreach(
        fun(Char) ->
            Header = list_to_binary([Char | "emqx"]),
            Tail = list_to_binary("emqx" ++ [Char]),
            Middle = <<Tail/binary, "emqx">>,
            Fun(#{<<"test_key">> => Header}, <<"test_key = \"", Header/binary, "\"\n">>),
            Fun(#{<<"test_key">> => Tail}, <<"test_key = \"", Tail/binary, "\"\n">>),
            Fun(#{<<"test_key">> => Middle}, <<"test_key = \"", Middle/binary, "\"\n">>)
        end,
        "'${}[]:=,+#`^?!@*& "
    ),
    ok.

load_file_pp_test() ->
    TmpF = "/tmp/load_file_pp_test",
    F = fun(Raw, Format) ->
        ok = file:write_file(TmpF, Raw),
        {ok, M} = hocon:load(TmpF, #{format => Format}),
        Bin = flatten(M),
        [I || I <- binary:split(Bin, <<"\n">>, [global]), I =/= <<>>]
    end,
    ?assertEqual(
        [
            <<"f1 = 1 # /tmp/load_file_pp_test:3">>,
            <<"foo = [] # /tmp/load_file_pp_test:1">>
        ],
        F("foo=[]\n\nf1=1", richmap)
    ),
    ?assertEqual(
        [
            <<"f1 = 1 # /tmp/load_file_pp_test:2">>,
            <<"foo.1 = \"a\" # /tmp/load_file_pp_test:1">>,
            <<"foo.2 = \"b\" # /tmp/load_file_pp_test:1">>
        ],
        F("foo=[a,b]\nf1=1", richmap)
    ).

load_binary_pp_test() ->
    Sc = #{
        roots => [root],
        fields => #{
            root => [{"val", hoconsc:mk(hoconsc:ref(sub))}],
            sub => [{"f1", integer()}]
        }
    },
    Conf = "root = {val = {f1 = 43}}",
    {ok, Raw} = hocon:binary(Conf, #{format => richmap}),
    M1 = hocon_tconf:check(Sc, Raw, #{}),
    M2 = hocon_tconf:check_plain(Sc, Raw, #{}),
    %% print source as comment
    ?assertEqual(<<"root.val.f1 = 43 # line=1\n">>, flatten(M1)),
    %% no source info to print
    ?assertEqual(<<"root.val.f1 = 43\n">>, flatten(M2)),
    ok.

env_flat_pp_test() ->
    Sc = #{
        roots => [root],
        fields => #{
            root => [{"val", hoconsc:mk(hoconsc:ref(sub))}],
            sub => [{"f1", integer()}]
        }
    },
    Conf = "root = {val = {f1 = 43}}",
    {ok, Raw} = hocon:binary(Conf, #{format => richmap}),
    Check = fun(F) ->
        with_envs(
            F,
            [Sc, Raw, #{apply_override_envs => true}],
            [
                {"HOCON_ENV_OVERRIDE_PREFIX", "EMQX_"},
                {"EMQX_ROOT__VAL", "{f1:42}"}
            ]
        )
    end,
    M1 = Check(fun hocon_tconf:check/3),
    M2 = Check(fun hocon_tconf:check_plain/3),
    %% print source as comment
    ?assertEqual(<<"root.val.f1 = 42 # EMQX_ROOT__VAL\n">>, flatten(M1)),
    %% no source info to print
    ?assertEqual(<<"root.val.f1 = 42\n">>, flatten(M2)),
    ok.

with_envs(Fun, Args, Envs) -> hocon_test_lib:with_envs(Fun, Args, Envs).

flatten(Map) ->
    iolist_to_binary(hocon_pp:flat_dump(Map)).

escape_test() ->
    {ok, Conf} = hocon:load("./test/data/unescape.conf"),
    PP = hocon_pp:do(Conf, #{}),
    {ok, Conf2} = hocon:binary(PP),
    ?assertEqual(Conf, Conf2).

utf8_test() ->
    InvalidUtf8 = #{<<"test">> => <<"测试-专用">>},
    ?assertThrow({invalid_utf8, _}, hocon_pp:do(InvalidUtf8, #{})),
    Utf8 = #{<<"test">> => <<"测试-专用"/utf8>>},
    PP = hocon_pp:do(Utf8, #{}),
    {ok, Conf} = hocon:binary(PP),
    ?assertEqual(Utf8, Conf),
    %% support utf8 key
    Utf81 = #{<<"测试-test-专用"/utf8>> => <<"测试-专用"/utf8>>},
    PP1 = hocon_pp:do(Utf81, #{}),
    {ok, Conf1} = hocon:binary(PP1),
    ?assertEqual(Utf81, Conf1).

map_with_placeholders_test() ->
    RawConf =
        #{ <<"headers">> =>
               #{
                 <<"fixed_key">> => <<"fixed_value">>,
                 <<"${.payload.key}">> => <<"fixed_value">>,
                 <<"${.payload.key}2">> => <<"${.payload.value}">>,
                 <<"fixed_key2">> => <<"${.payload.value}">>
                }
         },
    TmpFile = "/tmp/" ++ atom_to_list(?FUNCTION_NAME) ++ ".conf",
    try
        ok = file:write_file(TmpFile, hocon_pp:do(RawConf, #{})),
        {ok, LoadedConf} = hocon:load(TmpFile, #{format => map}),
        ?assertEqual(RawConf, LoadedConf),
        ok
    after
        file:delete(TmpFile)
    end.
