%% -------------------------------------------------------------------
%%
%% Copyright (c) 2019 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc NkLIB Config Server.
-module(nklib_config_parse_old).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([parse_config/3]).

-export_type([syntax/0]).


-type syntax_subopt() ::
    ignore | any | atom | boolean | {enum, [atom()]} | list | pid | proc | module |
    integer | pos_integer | nat_integer | {integer, none|integer(), none|integer()} |
    {integer, [integer()]} | float | {record, atom()} |
    string | binary | base64 | lower | upper |
    ip | ip4 | ip6 | host | host6 | {function, pos_integer()} |
    unquote | path | fullpath | uri | uris | tokens | words | map | log_level |
    map() | list() | syntax_fun().

-type syntax_fun() ::
    fun((atom(), term(), fun_ctx()) -> 
        ok | {ok, term()} | {ok, term(), term()} |
        {new_ok, [{atom(), term()}]} | error | {error, term()}) |
    fun((term()) -> 
        ok | {ok, term()} | {ok, term(), term()} |
        {new_ok, [{atom(), term()}]} | error | {error, term()}).


-type fun_ctx() ::
    parse_opts() | #{ok=>[{atom(), term()}], no_ok=>[{binary(), term()}]}.

-type syntax_opt() ::
    syntax_subopt() | {list|slist|ulist, syntax_subopt()} | 
    {update, map|list, MapOrList::atom(), Key::atom(), syntax_subopt()}.

-type syntax() :: #{ atom() => syntax_opt()}.

-type parse_opts() ::
    #{
        return => map|list,         % Default is list
        path => binary(),           % Returned in errors
        defaults => map() | list(), % Default and mandatory not allowed for nested
        mandatory => [atom()],
        warning_unknown => boolean()
    }.



%% ===================================================================
%% Public
%% ===================================================================



%% @doc Equivalent to parse_config(Terms, Spec, #{})
-spec parse_config(map()|list(), syntax()) ->
    {ok, [{atom(), term()}], [{binary(), term()}]} | 
    {ok, #{atom()=>term()}, #{binary()=>term()}} |
    {error, Error}
    when Error :: 
        {syntax_error, binary()} | 
        {missing_mandatory_field, binary()} |
        {invalid_spec, syntax_opt()} |
        term().

parse_config(Terms, Spec) ->
    parse_config(Terms, Spec, #{}).


%% @doc Parses a list of options
%% For lists, if duplicated entries, the last one wins
-spec parse_config(map()|list(), syntax(), parse_opts()) ->
    {ok, [{atom(), term()}], [{atom(), term()}]} | 
    {ok, #{atom()=>term()}, #{binary()=>term()}} | 
    {error, Error}
    when Error :: 
        {syntax_error, binary()} | 
        {missing_mandatory_field, binary()} |
        {invalid_spec, syntax_opt()} |
        term().

parse_config(Terms, Syntax, Opts) when is_list(Terms), is_map(Opts) ->
    try
        parse_config(Terms, [], [], Syntax, Opts)
    catch
        throw:Throw ->
            {error, Throw}
    end;

parse_config(Terms, Syntax, Opts) when is_map(Terms), is_map(Opts) ->
    parse_config(maps:to_list(Terms), Syntax, Opts).







%% ===================================================================
%% Private
%% ===================================================================



%% @private
-spec parse_config([{term(), term()}], [{atom(), term()}], [{atom(), term()}],
                   syntax(), parse_opts()) ->
    {ok, [{atom(), term()}], [{binary(), term()}]}.

parse_config([], OK, NoOK, Syntax, #{defaults:=Defaults}=Opts) ->
    case parse_config(Defaults, Syntax) of
        {ok, Defaults2, []} ->
            OK2 = nklib_util:defaults(OK, Defaults2),
            parse_config([], OK2, NoOK, Syntax, maps:remove(defaults, Opts));
        {ok, _, DefNoOK} ->
            lager:log(warning, self(), "Error parsing in defaults: ~p", [Defaults]),
            {error, {no_ok, DefNoOK}};
        {error, Error} ->
            lager:log(warning, self(), "Error parsing in defaults: ~p", [Defaults]),
            {error, Error}
    end;

parse_config([], OK, NoOK, _Syntax, Opts) ->
    OK2 = lists:reverse(OK),
    NoOK2 = lists:reverse(NoOK),
    Mandatory = maps:get(mandatory, Opts, []),
    case check_mandatory(Mandatory, OK) of
        ok ->
            case NoOK /= [] andalso maps:find(warning_unknown, Opts) of
                {ok, true} ->
                    lager:log(warning, self(), "Unknown keys in config: ~p", 
                                  [maps:from_list(NoOK)]);
                _ -> ok
            end,
            case Opts of
                #{return:=map} ->
                    {ok, maps:from_list(OK2), maps:from_list(NoOK)};
                _ ->
                    {ok, OK2, NoOK2}
            end;
        {missing, Key} ->
            {error, {missing_mandatory_field, nklib_util:to_binary(Key)}}
    end;

parse_config([{Key, Val}|Rest], OK, NoOK, Syntax, Opts) ->
    case to_existing_atom(Key) of
        {ok, AtomKey} ->
            find_config(AtomKey, Val, Rest, OK, NoOK, Syntax, Opts);
        error ->
            parse_config(Rest, OK, [{Key, Val}|NoOK], Syntax, Opts)
    end;

parse_config([Key|Rest], OK, NoOK, Syntax, Opts) ->
    parse_config([{Key, true}|Rest], OK, NoOK, Syntax, Opts).


%% @private
find_config(Key, Val, Rest, OK, NoOK, Syntax, Opts) ->
    case maps:get(Key, Syntax, not_found) of
        not_found ->
            parse_config(Rest, OK, [{Key, Val}|NoOK], Syntax, Opts);
        Fun when is_function(Fun) ->
            FunRes = if
                is_function(Fun, 3) -> 
                    FunOpts = Opts#{ok=>OK, no_ok=>NoOK},
                    catch Fun(Key, Val, FunOpts);
                is_function(Fun, 1) ->
                    catch Fun(Val)
            end,
            case FunRes of
                ok ->
                    parse_config(Rest, [{Key, Val}|OK], NoOK, Syntax, Opts);
                {ok, Val1} ->
                    parse_config(Rest, [{Key, Val1}|OK], NoOK, Syntax, Opts);
                {ok, Key1, Val1} when is_atom(Key1) ->
                    parse_config(Rest, [{Key1, Val1}|OK], NoOK, Syntax, Opts);
                {new_ok, OKB} ->
                    parse_config(Rest, OKB, NoOK, Syntax, Opts);
                error ->
                    throw_syntax_error(Key, Opts);
                {error, Error} ->
                    throw(Error);
                {'EXIT', Error} ->
                    lager:log(warning, self(), "Error calling syntax fun: ~p", [Error]),
                    throw({internal_error, ?MODULE, ?LINE})
            end;
        SubSyntax when is_map(SubSyntax) ->
            case is_list(Val) orelse is_map(Val) of
                true ->
                    BinKey = nklib_util:to_binary(Key),
                    Opts1 = maps:remove(defaults, Opts),
                    Opts2 = maps:remove(mandatory, Opts1),
                    Opts3 = Opts2#{path=>BinKey},
                    case parse_config(Val, SubSyntax, Opts3) of
                        {ok, Val1, _SubNoOK} ->
                            parse_config(Rest, [{Key, Val1}|OK], NoOK, Syntax, Opts);
                        {error, {syntax_error, Error}} ->
                            throw_syntax_error(Error, Opts);
                        {error, Term} ->
                            throw(Term)
                    end;
                false ->
                    throw_syntax_error(Key, Opts)
            end;
        {update, UpdType, Index2, Key2, SubSyntax} ->
            case do_parse_config(SubSyntax, Val) of
                {ok, Val2} ->
                    NewOK = case lists:keytake(Index2, 1, OK) of
                        false when UpdType==map -> 
                            [{Index2, maps:put(Key2, Val2, #{})}|OK];
                        false when UpdType==list -> 
                            [{Index2, [{Key2, Val2}]}|OK];
                        {value, {Index2, Base}, OKA} when UpdType==map ->
                            [{Index2, maps:put(Key2, Val2, Base)}|OKA];
                        {value, {Index2, Base}, OKA} when UpdType==list ->
                            [{Index2, [{Key2, Val2}|Base]}|OKA]
                    end,
                    parse_config(Rest, NewOK, NoOK, Syntax, Opts);
                error ->
                    throw_syntax_error(Key, Opts)
            end;
        ignore ->
            parse_config(Rest, OK, NoOK, Syntax, Opts);
        SyntaxOp ->
            case do_parse_config(SyntaxOp, Val) of
                {ok, Val1} ->
                    parse_config(Rest, [{Key, Val1}|OK], NoOK, Syntax, Opts);
                error ->
                    throw_syntax_error(Key, Opts);
                unknown ->
                    throw({invalid_spec, SyntaxOp})
            end
    end.


%% @private
to_existing_atom(Term) when is_atom(Term) ->
    {ok, Term};

to_existing_atom(Term) ->
    case catch list_to_existing_atom(nklib_util:to_list(Term)) of
        {'EXIT', _} -> error;
        Atom -> {ok, Atom}
    end.


%% @private
throw_syntax_error(Key, #{path:=Path}) ->
    Path1 = <<
        (nklib_util:to_binary(Path))/binary, $.,
        (nklib_util:to_binary(Key))/binary>>,
    throw({syntax_error, Path1});

throw_syntax_error(Key, _) ->
    throw({syntax_error, nklib_util:to_binary(Key)}).



%% @private
check_mandatory([], _) ->
    ok;

check_mandatory([Key|Rest], All) ->
    case lists:keymember(Key, 1, All) of
        true -> check_mandatory(Rest, All);
        false -> {missing, Key}
    end.


%% @private
-spec do_parse_config(syntax_opt(), term()) ->
    {ok, term()} | error | unknown.

do_parse_config(any, Val) ->
    {ok, Val};

do_parse_config(atom, Val) ->
    to_existing_atom(Val);

do_parse_config(boolean, Val) when Val==0; Val=="0" ->
    {ok, false};

do_parse_config(boolean, Val) when Val==1; Val=="1" ->
    {ok, true};

do_parse_config(boolean, Val) ->
    case nklib_util:to_boolean(Val) of
        true -> {ok, true};
        false -> {ok, false};
        error -> error
    end;

do_parse_config({enum, List}, Val) ->
    case to_existing_atom(Val) of
        {ok, Atom} ->
            case lists:member(Atom, List) of
                true -> {ok, Atom};
                false -> error
            end;
        error ->
            error
    end;

do_parse_config(list, Val) ->
    case is_list(Val) of
        true -> {ok, Val};
        false -> error
    end;

do_parse_config({List, Type}, Val) when List==list; List==slist; List==ulist ->
    case Val of
        [] ->
            {ok, []};
        [Head|_] when not is_integer(Head) ->
            do_parse_config_list(List, Val, Type, []);
        _ -> 
            do_parse_config_list(List, [Val], Type, [])
    end;

do_parse_config(proc, Val) ->
    case is_atom(Val) orelse is_pid(Val) of
        true -> {ok, Val};
        false -> error
    end;

do_parse_config(pid, Val) ->
    case is_pid(Val) of
        true -> {ok, Val};
        false -> error
    end;

do_parse_config(module, Val) ->
    case code:ensure_loaded(Val) of
        {module, Val} -> {ok, Val};
        _ -> error
    end;

do_parse_config(integer, Val) ->
    do_parse_config({integer, none, none}, Val);

do_parse_config(pos_integer, Val) ->
    do_parse_config({integer, 0, none}, Val);

do_parse_config(nat_integer, Val) ->
    do_parse_config({integer, 1, none}, Val);

do_parse_config({integer, Min, Max}, Val) ->
    case nklib_util:to_integer(Val) of
        error -> 
            error;
        Int when 
            (Min==none orelse Int >= Min) andalso
            (Max==none orelse Int =< Max) ->
            {ok, Int};
        _ ->
            error
    end;

do_parse_config({integer, List}, Val) when is_list(List) ->
    case nklib_util:to_integer(Val) of
        error -> 
            error;
        Int ->
            case lists:member(Int, List) of
                true -> {ok, Int};
                false -> error
        end
    end;
    
do_parse_config(float, Val) ->
    case nklib_util:to_float(Val) of
        error -> 
            error;
        Float ->
            {ok, Float}
    end;

do_parse_config({record, Type}, Val) ->
    case is_record(Val, Type) of
        true -> {ok, Val};
        false -> error
    end;

do_parse_config(string, Val) ->
    if 
        is_list(Val) ->
            case catch erlang:list_to_binary(Val) of
                {'EXIT', _} -> error;
                Bin -> {ok, erlang:binary_to_list(Bin)}
            end;
        is_binary(Val); is_atom(Val); is_integer(Val) ->
            {ok, nklib_util:to_list(Val)};
        true ->
            error
    end;

do_parse_config(binary, Val) ->
    if
        is_binary(Val) ->
            {ok, Val};
        Val==[] ->
            {ok, <<>>};
        is_list(Val), is_integer(hd(Val)) ->
            case catch list_to_binary(Val) of
                {'EXIT', _} -> error;
                Bin -> {ok, Bin}
            end;
        is_atom(Val); is_integer(Val) ->
            {ok, nklib_util:to_binary(Val)};
        true ->
            error
    end;
 
do_parse_config(base64, Val) ->
    case catch base64:decode(Val) of
        {'EXIT', _} ->
            error;
        Bin ->
            {ok, Bin}
    end;

do_parse_config(lower, Val) ->
    case do_parse_config(string, Val) of
        {ok, List} -> {ok, nklib_util:to_lower(List)};
        error -> error
    end;

do_parse_config(upper, Val) ->
    case do_parse_config(string, Val) of
        {ok, List} -> {ok, nklib_util:to_upper(List)};
        error -> error
    end;

do_parse_config(ip, Val) ->
    case nklib_util:to_ip(Val) of
        {ok, Ip} -> {ok, Ip};
        _ -> error
    end;

do_parse_config(ip4, Val) ->
    case nklib_util:to_ip(Val) of
        {ok, {_, _, _, _}=Ip} -> {ok, Ip};
        _ -> error
    end;

do_parse_config(ip6, Val) ->
    case nklib_util:to_ip(Val) of
        {ok, {_, _, _, _, _, _, _, _}=Ip} -> {ok, Ip};
        _ -> error
    end;

do_parse_config(host, Val) ->
    {ok, nklib_util:to_host(Val)};

do_parse_config(host6, Val) ->
    case nklib_util:to_ip(Val) of
        {ok, HostIp6} -> 
            % Ensure it is enclosed in `[]'
            {ok, nklib_util:to_host(HostIp6, true)};
        error -> 
            {ok, nklib_util:to_binary(Val)}
    end;

do_parse_config({function, N}, Val) ->
    case is_function(Val, N) of
        true -> {ok, Val};
        false -> error
    end;

do_parse_config(unquote, Val) when is_list(Val); is_binary(Val) ->
    case nklib_parse:unquote(Val) of
        error -> error;
        Bin -> {ok, Bin}
    end;

do_parse_config(path, Val) when is_list(Val); is_binary(Val) ->
    {ok, nklib_parse:path(Val)};

do_parse_config(fullpath, Val) when is_list(Val); is_binary(Val) ->
    {ok, nklib_parse:fullpath(filename:absname(Val))};

do_parse_config(uri, Val) ->
    case nklib_parse:uris(Val) of
        [Uri] -> {ok, Uri};
        _r -> error
    end;

do_parse_config(uris, Val) ->
    case nklib_parse:uris(Val) of
        error -> error;
        Uris -> {ok, Uris}
    end;

do_parse_config(tokens, Val) ->
    case nklib_parse:tokens(Val) of
        error -> error;
        Tokens -> {ok, Tokens}
    end;

do_parse_config(words, Val) ->
    case nklib_parse:tokens(Val) of
        error -> error;
        Tokens -> {ok, [W || {W, _} <- Tokens]}
    end;

do_parse_config(log_level, Val) when Val>=0, Val=<8 -> 
    {ok, Val};

do_parse_config(log_level, Val) ->
    case Val of
        debug -> {ok, 8};
        info -> {ok, 7};
        notice -> {ok, 6};
        warning -> {ok, 5};
        error -> {ok, 4};
        critical -> {ok, 3};
        alert -> {ok, 2};
        emergency -> {ok, 1};
        none -> {ok, 0};
        _ -> error
    end;

do_parse_config(map, Map) ->
    case is_map(Map) andalso do_parse_config_map(maps:to_list(Map)) of
        ok -> {ok, Map};
        _ -> error
    end;

do_parse_config([Opt|Rest], Val) ->
    case catch do_parse_config(Opt, Val) of
        {ok, Val1} -> {ok, Val1};
        _ -> do_parse_config(Rest, Val)
    end;

do_parse_config([], _Val) ->
    error;

do_parse_config(_Type, _Val) ->
    unknown.


%% @private
do_parse_config_list(list, [], _Type, Acc) ->
    {ok, lists:reverse(Acc)};

do_parse_config_list(slist, [], _Type, Acc) ->
    {ok, lists:sort(Acc)};

do_parse_config_list(ulist, [], _Type, Acc) ->
    {ok, lists:usort(Acc)};

do_parse_config_list(ListType, [Term|Rest], Type, Acc) ->
    case do_parse_config(Type, Term) of
        {ok, Val} ->
            do_parse_config_list(ListType, Rest, Type, [Val|Acc]);
        error ->
            error
    end;

do_parse_config_list(_, _, _, _) ->
    error.

%% @private
do_parse_config_map([]) -> 
    ok;

do_parse_config_map([{Key, Val}|Rest]) ->
    case is_binary(Key) orelse is_atom(Key) of
        true when is_map(Val) ->
            case do_parse_config_map(maps:to_list(Val)) of
                ok ->
                    do_parse_config_map(Rest);
                error ->
                    error
            end;
        true ->
            do_parse_config_map(Rest);
        false ->
            error
    end.


     

%% ===================================================================
%% EUnit tests
%% ===================================================================


% -compile([export_all]).
% -define(TEST, 1).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-dialyzer({[no_match, no_return], parse1_test/0}).


parse1_test() ->
    Spec = #{
        field01 => atom,
        field02 => boolean,
        field03 => {enum, [a, b]},
        field04 => integer,
        field05 => {integer, 1, 5},
        field06 => string,
        field07 => binary,
        field08 => host,
        field09 => host6,
        field10 => fun parse_fun/3,
        field11 => [{enum, [a]}, binary],
        field12 => 
            #{
                field12_a => atom,
                field12_b => integer
            },
        field13 => {list, atom},
        field14 => {update, map, map1, m_field14, integer},
        field15 => {update, map, map1, m_field15, atom},
        field16 => module,
        fieldXX => invalid
    },

    {ok, [], []} = parse_config([], Spec),
    {ok, [], []} = parse_config(#{}, Spec),

    {error, {syntax_error, <<"field01">>}} = parse_config([{field01, "12345"}], Spec),
    
    {ok,[{field01, fieldXX}, {field02, false}],[{unknown, a}]} = 
        parse_config(
            [{field01, "fieldXX"}, {field02, <<"false">>}, {"unknown", a}],
            Spec),

    {ok,[
        {field03, b},
        {field04, -1},
        {field05, 2},
        {field06, "a"},
        {field07, <<"b">>},
        {field08, <<"host">>},
        {field09, <<"[::1]">>}
    ], []} = 
        parse_config(
            [{field03, <<"b">>}, {"field04", -1}, {field05, 2}, {field06, "a"}, 
            {field07, "b"}, {<<"field08">>, "host"}, {field09, <<"::1">>}],
            Spec),

    {error, {syntax_error, <<"field03">>}} = parse_config([{field03, c}], Spec),
    {error, {syntax_error, <<"mypath.field05">>}} = 
        parse_config([{field05, 0}], Spec, #{path=><<"mypath">>}),
    {error, {syntax_error, <<"field05">>}} = parse_config([{field05, 6}], Spec),
    {error, {invalid_spec, invalid}} = parse_config([{fieldXX, a}], Spec),

    {ok, [{field10, data1}], []} = parse_config([{field10, data}], Spec),
    {ok, [{field01, false}], []} = parse_config([{field01, true}, {field10, opts}], Spec),

    {ok, [{field11, a}], []} = parse_config([{field11, a}], Spec),
    {ok, [{field11, <<"b">>}], []} = parse_config([{field11, b}], Spec),

    {error, {syntax_error, <<"field12">>}} = parse_config([{field12, a}], Spec),
    {error, {syntax_error, <<"field12.field12_a">>}} = 
        parse_config([{field12, [{field12_a, 1}]}], Spec),
    {error, {syntax_error, <<"mypath.field12.field12_a">>}} = 
        parse_config([{field12, [{field12_a, 1}]}], Spec, #{path=><<"mypath">>}),

    % Field 12c is ignored
    {ok, [{field12, [{field12_a, ok},{field12_b, 1}]}],[]} = Sub1 = 
        parse_config(
            [{field12, [{field12_a, "ok"}, {field12_b, "1"}, {field_12_c, none}]}], 
            Spec),
    Sub1 = 
        parse_config(
            #{field12 => #{field12_a=>"ok", field12_b=>"1", field_12_c=>none}},
            Spec),
    {ok, #{field12 := #{field12_a:=ok, field12_b:=1}}, #{}} = Sub2 = 
        parse_config(
            [{field12, [{field12_a, "ok"}, {field12_b, "1"}, {field_12_c, none}]}], 
            Spec, #{return=>map}),
    Sub2 = 
        parse_config(
            #{field12 => #{field12_a=>"ok", field12_b=>"1", field_12_c=>none}},
            Spec, #{return=>map}),

    {ok, [{field13, [a, b, '3']}], []} = parse_config(#{field13 => [a, "b", 3]}, Spec),

    {ok, [{field01, a}, {map1, #{m_field14:=1, m_field15:=b}}],[]} = 
        parse_config(#{field01=>a, field14=>1, field15=>b}, Spec),

    {ok, #{field01:=a, map1:=#{m_field14:=1, m_field15:=b}}, #{}} = 
        parse_config([{field01, a}, {field14, 1}, {field15, b}], Spec, #{return=>map}),

    {error, {syntax_error, <<"field14">>}} = parse_config(#{field01=>a, field14=>a}, Spec),

    {error, {syntax_error, <<"field16">>}} = parse_config([{field16, kkk383838}], Spec),
    {ok, [{field16, string}], []} = parse_config([{field16, string}], Spec),

    ok.


parse_fun(field10, data, _Opts) ->
    {ok, data1};
parse_fun(field10, opts, #{ok:=OK}) ->
    {new_ok, lists:keystore(field01, 1, OK, {field01, false})}.


-endif.










