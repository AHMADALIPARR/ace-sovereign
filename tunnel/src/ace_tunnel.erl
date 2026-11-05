%% ace_tunnel — shared helpers for the hand-rolled reverse tunnel:
%% configuration, key handling, HMAC authentication, and socket pumps.
%%
%% The tunnel is ngrok-shaped and bare metal: an inside agent dials OUT
%% to a relay the owner controls; the relay is the only public listener.
%% No vendor, no API, no account. Authentication is a shared key the
%% operator generates (make-key.sh) and places on both hosts by hand —
%% the owner's own cryptographic key, like his SSH keys.
-module(ace_tunnel).
-export([cfg/2, load_key/1, hmac_hex/2, hex/1, unhex/1, pump/2, nonce_hex/0]).

cfg(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.

%% Key file: a single hex string (64 chars = 32 bytes), whitespace trimmed.
load_key(Path) ->
    {ok, Raw} = file:read_file(Path),
    Hex = string:trim(binary_to_list(Raw)),
    unhex(Hex).

hmac_hex(Key, Data) ->
    hex(crypto:mac(hmac, sha256, Key, Data)).

nonce_hex() -> hex(crypto:strong_rand_bytes(16)).

hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || B <- binary_to_list(Bin)]).

unhex(Hex) ->
    unhex(Hex, []).

unhex([], Acc) ->
    list_to_binary(lists:reverse(Acc));
unhex([A, B | Rest], Acc) ->
    unhex(Rest, [digit(A) * 16 + digit(B) | Acc]).

digit(C) when C >= $0, C =< $9 -> C - $0;
digit(C) when C >= $a, C =< $f -> C - $a + 10;
digit(C) when C >= $A, C =< $F -> C - $A + 10.

%% pump(From, To) — copy bytes until either side closes, then close both.
%% Runs as its own process per direction; a stream uses two pumps.
pump(From, To) ->
    case gen_tcp:recv(From, 0) of
        {ok, Data} ->
            case gen_tcp:send(To, Data) of
                ok -> pump(From, To);
                {error, _} -> shutdown(From, To)
            end;
        {error, _} -> shutdown(From, To)
    end.

shutdown(A, B) ->
    gen_tcp:close(A),
    gen_tcp:close(B),
    ok.
