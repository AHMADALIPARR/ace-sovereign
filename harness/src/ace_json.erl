%% ace_json — a small, dependency-free JSON codec, sized for the harness
%% protocol: objects, arrays, strings, integers, booleans, null.
%% Maps use binary keys; strings decode to binaries.
-module(ace_json).
-export([encode/1, decode/1]).

%% ---- encode ----

encode(Map) when is_map(Map) ->
    Items = [[$", escape(key_bin(K)), $", $:, encode(V)] || {K, V} <- maps:to_list(Map)],
    iolist_to_binary([${, join(Items, $,), $}]);
encode(List) when is_list(List) ->
    iolist_to_binary([$[, join([encode(V) || V <- List], $,), $]]);
encode(Bin) when is_binary(Bin) ->
    iolist_to_binary([$", escape(Bin), $"]);
encode(Int) when is_integer(Int) ->
    integer_to_binary(Int);
encode(true) -> <<"true">>;
encode(false) -> <<"false">>;
encode(null) -> <<"null">>.

key_bin(B) when is_binary(B) -> B;
key_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
key_bin(L) when is_list(L) -> list_to_binary(L).

join([], _Sep) -> [];
join([H | T], Sep) -> [H | [[Sep, X] || X <- T]].

escape(Bin) ->
    [escape_char(C) || C <- binary_to_list(Bin)].

escape_char($") -> "\\\"";
escape_char($\\) -> "\\\\";
escape_char($\n) -> "\\n";
escape_char($\r) -> "\\r";
escape_char($\t) -> "\\t";
escape_char(C) when C < 16#20 -> io_lib:format("\\u~4.16.0b", [C]);
escape_char(C) -> [C].

%% ---- decode ----

decode(Bin) when is_binary(Bin) ->
    try
        {Value, Rest} = parse_value(skip_ws(binary_to_list(Bin))),
        case skip_ws(Rest) of
            [] -> {ok, Value};
            _ -> {error, trailing_data}
        end
    catch
        throw:{json, Reason} -> {error, Reason};
        _: _ -> {error, invalid}
    end.

skip_ws([C | Rest]) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r -> skip_ws(Rest);
skip_ws(S) -> S.

parse_value([${ | Rest]) -> parse_object(skip_ws(Rest), #{});
parse_value([$[ | Rest]) -> parse_array(skip_ws(Rest), []);
parse_value([$" | Rest]) -> parse_string(Rest, []);
parse_value("true" ++ Rest) -> {true, Rest};
parse_value("false" ++ Rest) -> {false, Rest};
parse_value("null" ++ Rest) -> {null, Rest};
parse_value(S) -> parse_number(S).

parse_object([$} | Rest], Map) -> {Map, Rest};
parse_object([$" | Rest], Map) ->
    {Key, Rest1} = parse_string(Rest, []),
    case skip_ws(Rest1) of
        [$: | Rest2] ->
            {Value, Rest3} = parse_value(skip_ws(Rest2)),
            Map2 = Map#{Key => Value},
            case skip_ws(Rest3) of
                [$, | Rest4] -> parse_object(skip_ws(Rest4), Map2);
                [$} | Rest4] -> {Map2, Rest4};
                _ -> throw({json, bad_object})
            end;
        _ -> throw({json, bad_object})
    end;
parse_object(_, _) -> throw({json, bad_object}).

parse_array([$] | Rest], Acc) -> {lists:reverse(Acc), Rest};
parse_array(S, Acc) ->
    {Value, Rest1} = parse_value(S),
    case skip_ws(Rest1) of
        [$, | Rest2] -> parse_array(skip_ws(Rest2), [Value | Acc]);
        [$] | Rest2] -> {lists:reverse([Value | Acc]), Rest2};
        _ -> throw({json, bad_array})
    end.

parse_string([$" | Rest], Acc) ->
    {list_to_binary(lists:reverse(Acc)), Rest};
parse_string([$\\, C | Rest], Acc) ->
    Ch = case C of
             $" -> $";
             $\\ -> $\\;
             $/ -> $/;
             $n -> $\n;
             $r -> $\r;
             $t -> $\t;
             $b -> $\b;
             $f -> $\f;
             $u -> throw({json, unicode_escape_unsupported});
             _ -> throw({json, bad_escape})
         end,
    parse_string(Rest, [Ch | Acc]);
parse_string([C | Rest], Acc) ->
    parse_string(Rest, [C | Acc]);
parse_string([], _) ->
    throw({json, unterminated_string}).

parse_number(S) ->
    parse_number(S, []).

parse_number([C | Rest], Acc) when C >= $0, C =< $9; C =:= $- ->
    parse_number(Rest, [C | Acc]);
parse_number(Rest, [_ | _] = Acc) ->
    {list_to_integer(lists:reverse(Acc)), Rest};
parse_number(_, _) ->
    throw({json, bad_value}).
