%% ace_agent — the inside half of the tunnel. Runs on the sandbox host,
%% behind whatever NAT or firewall it lives behind. It makes ONLY
%% outbound connections:
%%   * one control connection to the relay (authenticated by HMAC over
%%     the relay's nonce, keyed by the owner's own tunnel key);
%%   * one data connection per public stream the relay asks it to open,
%%     spliced to the local target (the harness) on 127.0.0.1.
%% The inside host exposes no listener to the tunnel at all.
-module(ace_agent).
-export([run_forever/0, run_once/0]).

-record(cfg, {host, port, name, key, target_port}).

config() ->
    #cfg{
        host = ace_tunnel:cfg("ACE_RELAY_HOST", "127.0.0.1"),
        port = list_to_integer(ace_tunnel:cfg("ACE_AGENT_PORT", "7701")),
        name = ace_tunnel:cfg("ACE_TUNNEL_NAME", "jetson"),
        key = ace_tunnel:load_key(
                ace_tunnel:cfg("ACE_TUNNEL_KEYFILE",
                               filename:join(os:getenv("HOME"), ".ace-tunnel-key"))),
        target_port = list_to_integer(ace_tunnel:cfg("ACE_TARGET_PORT", "8765"))
    }.

run_forever() ->
    Cfg = config(),
    loop_forever(Cfg).

loop_forever(Cfg) ->
    case session(Cfg) of
        ok -> io:format("ace_agent: control session ended, reconnecting~n");
        {error, Reason} -> io:format("ace_agent: session failed: ~p, retrying~n", [Reason])
    end,
    timer:sleep(2000),
    loop_forever(Cfg).

%% One control session. Returns ok when it ends cleanly,
%% {error, auth_refused} when the relay rejects the key, or
%% {error, Reason} for transport failures.
run_once() ->
    session(config()).

session(Cfg = #cfg{host = Host, port = Port, name = Name, key = Key}) ->
    Opts = [binary, {packet, line}, {active, false}],
    case gen_tcp:connect(Host, Port, Opts, 10000) of
        {ok, Sock} ->
            case read_nonce(Sock) of
                {ok, Nonce} ->
                    Mac = ace_tunnel:hmac_hex(Key, ["hello:", Nonce, ":", Name]),
                    ok = gen_tcp:send(Sock, "HELLO " ++ Name ++ " " ++ Mac ++ "\n"),
                    case gen_tcp:recv(Sock, 0, 10000) of
                        {ok, <<"OK", _/binary>>} ->
                            io:format("ace_agent: registered with relay as ~s~n", [Name]),
                            inet:setopts(Sock, [{packet, line}]),
                            control_loop(Sock, Cfg);
                        {ok, <<"ERR", _/binary>>} ->
                            gen_tcp:close(Sock),
                            {error, auth_refused};
                        {error, Reason} ->
                            gen_tcp:close(Sock),
                            {error, Reason}
                    end;
                {error, Reason} ->
                    gen_tcp:close(Sock),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

read_nonce(Sock) ->
    case gen_tcp:recv(Sock, 0, 10000) of
        {ok, Line} ->
            case string:tokens(string:trim(binary_to_list(Line)), " ") of
                ["NONCE", Nonce] -> {ok, Nonce};
                _ -> {error, bad_greeting}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

control_loop(Sock, Cfg) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, Line} ->
            case string:tokens(string:trim(binary_to_list(Line)), " ") of
                ["OPEN", Id] ->
                    spawn(fun() -> stream_worker(Id, Cfg) end),
                    control_loop(Sock, Cfg);
                _ ->
                    control_loop(Sock, Cfg)
            end;
        {error, closed} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

%% One public stream: dial a fresh data connection to the relay, prove
%% the stream id with the key, then splice to the local target.
stream_worker(Id, #cfg{host = Host, port = Port, key = Key, target_port = TargetPort}) ->
    Opts = [binary, {packet, line}, {active, false}],
    case gen_tcp:connect(Host, Port, Opts, 10000) of
        {ok, Data} ->
            case read_nonce(Data) of
                {ok, _Nonce} ->
                    Mac = ace_tunnel:hmac_hex(Key, ["stream:", Id]),
                    ok = gen_tcp:send(Data, "STREAM " ++ Id ++ " " ++ Mac ++ "\n"),
                    case gen_tcp:recv(Data, 0, 10000) of
                        {ok, <<"GO", _/binary>>} ->
                            splice(Data, TargetPort);
                        _ ->
                            gen_tcp:close(Data)
                    end;
                _ ->
                    gen_tcp:close(Data)
            end;
        {error, _} ->
            ok
    end.

splice(Data, TargetPort) ->
    case gen_tcp:connect("127.0.0.1", TargetPort, [binary, {packet, raw}, {active, false}], 10000) of
        {ok, Local} ->
            inet:setopts(Data, [{packet, raw}]),
            PumpA = spawn(ace_tunnel, pump, [Data, Local]),
            PumpB = spawn(ace_tunnel, pump, [Local, Data]),
            gen_tcp:controlling_process(Data, PumpA),
            gen_tcp:controlling_process(Local, PumpB),
            ok;
        {error, _} ->
            gen_tcp:close(Data)
    end.
