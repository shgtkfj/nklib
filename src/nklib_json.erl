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

%% @doc JSON Processing
-module(nklib_json).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-export([encode/1, encode_pretty/1, encode_sorted/1, decode/1, json_ish/1]).


%% ===================================================================
%% Public
%% ===================================================================


%% @doc Encodes a term() to JSON
%% To use jiffy instead of jsone, include it as a dependency in you
%% application and it will be used automatically
-spec encode(term()) ->
    binary() | error.

encode(Term) ->
    Fun = fun() ->
        case nklib_util:do_config_get(nklib_json_encoder) of
            jsone ->
                jsone:encode(Term);
            jiffy ->
                case jiffy:encode(Term) of
                    Json when is_binary(Json) -> Json;
                    List when is_list(List) -> list_to_binary(List)
                end
        end
    end,
    case nklib_util:do_try(Fun) of
        {exception, {error, {Error, Trace}}} ->
            lager:log(debug, self(), "Error encoding JSON: ~p (~p) (~p)", [Error, Term, Trace]),
            error({json_encode_error, Error});
        {exception, {throw, {Error, Trace}}} ->
            lager:log(debug, self(), "Error encoding JSON: ~p (~p) (~p)", [Error, Term, Trace]),
            error({json_encode_error, Error});
        Other ->
            Other
    end.


%% @doc Encodes a term() to JSON
-spec encode_pretty(term()) ->
    binary().

encode_pretty(Term) ->
    Fun = fun() ->
        case nklib_util:do_config_get(nklib_json_encoder) of
            jsone ->
                jsone:encode(Term, [{indent, 1}, {space, 2}]);
            jiffy ->
                case jiffy:encode(Term, [pretty]) of
                    Json when is_binary(Json) -> Json;
                    List when is_list(List) -> list_to_binary(List)
                end
        end
    end,
    case nklib_util:do_try(Fun) of
        {exception, {error, {Error, Trace}}} ->
            lager:log(debug, self(), "Error encoding JSON: ~p (~p) (~p)", [Error, Term, Trace]),
            error({json_encode_error, Error});
        {exception, {throw, {Error, Trace}}} ->
            lager:log(debug, self(), "Error encoding JSON: ~p (~p) (~p)", [Error, Term, Trace]),
            error({json_encode_error, Error});
        Other ->
            Other
    end.


%% @doc Encodes a term() to JSON sorting the keys
-spec encode_sorted(term()) ->
    binary().

encode_sorted(Term) ->
    encode_pretty(sort_json(Term)).


%% @private
sort_json(Map) when is_map(Map) ->
    {[{Key, sort_json(Val)} || {Key, Val} <- lists:sort(maps:to_list(Map))]};

sort_json(List) when is_list(List) ->
    [sort_json(Term) || Term <- List];

sort_json(Term) ->
    Term.


%% @doc Decodes a JSON as a map
-spec decode(binary()|iolist()) ->
    term().

decode(<<>>) ->
    <<>>;

decode([]) ->
    <<>>;

decode(Term) ->
    Fun = fun() ->
        case nklib_util:do_config_get(nklib_json_encoder) of
            jsone when is_binary(Term)->
                jsone:decode(Term);
            jsone when is_list(Term)->
                jsone:decode(list_to_binary(Term));
            jiffy ->
                jiffy:decode(Term, [return_maps])
        end
    end,
    case nklib_util:do_try(Fun) of
        {exception, {error, {Error, Trace}}} ->
            lager:log(debug, self(), "Error decoding JSON: ~p (~p) (~p)", [Error, Term, Trace]),
            error({json_decode_error, Error});
        {exception, {throw, {Error, Trace}}} ->
            lager:log(debug, self(), "Error decoding JSON: ~p (~p) (~p)", [Error, Term, Trace]),
            error({json_decode_error, Error});
        Other ->
            Other
    end.



%% @doc Makes a map json-ish (keys as binary, values as json)
json_ish(Map) ->
    maps:fold(
        fun(K, V, Acc) ->
            V2 = if
                is_binary(V); is_integer(V); is_float(V); is_boolean(V) ->
                    V;
                V==null ->
                    V;
                true ->
                    to_bin(V)
            end,
            Acc#{to_bin(K) => V2}
        end,
        #{},
        Map).


%% @private
to_bin(T) when is_binary(T)-> T;
to_bin(T) -> nklib_util:to_binary(T).



