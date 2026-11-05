%% ace_relay — the public side of the tunnel. Runs on a host the owner
%% controls that can hold a public port. Two listeners:
%%   * agent port  — the inside agent's outbound connections land here
%%                   (one control connection, plus one data connection
%%                   per public stream). Authenticated by HMAC over a
%%                   relay-issued nonce, keyed by the owner's own key.
%%   * public port — arbitrary clients. Each connection is paired with
%%                   a fresh agent data connection and spliced to it.
%% The relay holds no harness and no credentials beyond the tunnel key.
-module(ace_relay).
-behaviour(gen_server).
-export([start/0, start/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {key, control = undefined, pending = #{}}).

start() ->
    AgentPort = list_to_integer(ace_tunnel:cfg("ACE_AGENT_PORT", "7701")),
    PublicPort = list_to_integer(ace_tunnel:cfg("ACE_PUBLIC_PORT", "8801")),
    KeyFile = ace_tunnel:cfg("ACE_TUNNEL_KEYFILE", filename:join(os:getenv("HOME"), ".ace-tunnel-key")),
    start(AgentPort, PublicPort, KeyFile).

start(AgentPort, PublicPort, KeyFile) ->
    Key = ace_tunnel:load_key(KeyFile),
    {ok, Pid} = gen_server:start_link({local, ace_relay}, ace_relay, [Key], []),
    {ok, _} = acceptor(agent, AgentPort, Pid),
    {ok, _} = acceptor(public, PublicPort, Pid),
    io:format("ace_relay: agent port ~p, public port ~p~n", [AgentPort, PublicPort]),
    {ok, Pid}.

acceptor(Kind, Port, Broker) ->
    Pid = spawn_link(fun() ->
        {ok, LSock} = gen_tcp:listen(Port, [binary, {packet, line}, {active, false},
                                            {reuseaddr, true}, {ip, {0, 0, 0, 0}}]),
        accept_loop(Kind, LSock, Broker)
    end),
    {ok, Pid}.

accept_loop(Kind, LSock, Broker) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            case Kind of
                agent ->
                    HPid = spawn(fun() -> handshake(Sock, Broker) end),
                    gen_tcp:controlling_process(Sock, HPid);
                public ->
                    gen_tcp:controlling_process(Sock, Broker),
                    gen_server:cast(Broker, {public_conn, Sock})
            end,
            accept_loop(Kind, LSock, Broker);
        {error, closed} -> ok
    end.

%% First line on an agent-port connection decides its role, after the
%% relay issues a nonce: "HELLO <name> <hmac>" (control) or
%% "STREAM <id> <hmac>" (data for one public stream). The handshake
%% process owns the socket until the broker rules; socket ownership is
%% only ever transferred by its owner, per gen_tcp rules.
handshake(Sock, Broker) ->
    Nonce = ace_tunnel:nonce_hex(),
    ok = gen_tcp:send(Sock, "NONCE " ++ Nonce ++ "\n"),
    case gen_tcp:recv(Sock, 0, 10000) of
        {ok, Line} ->
            case string:tokens(string:trim(binary_to_list(Line)), " ") of
                ["HELLO", Name, Mac] ->
                    gen_server:cast(Broker, {hello, self(), Sock, Name, Nonce, Mac}),
                    await_ruling(Sock, control);
                ["STREAM", Id, Mac] ->
                    gen_server:cast(Broker, {stream, self(), Sock, Id, Mac}),
                    await_ruling(Sock, stream);
                _ ->
                    gen_tcp:close(Sock)
            end;
        {error, _} ->
            gen_tcp:close(Sock)
    end.

await_ruling(Sock, control) ->
    receive
        {broker, {control, Watcher}} ->
            inet:setopts(Sock, [{packet, raw}]),
            gen_tcp:controlling_process(Sock, Watcher),
            ok;
        {broker, drop} ->
            gen_tcp:close(Sock)
    after 15000 ->
        gen_tcp:close(Sock)
    end;
await_ruling(Sock, stream) ->
    receive
        {broker, {pair, PublicSock}} ->
            inet:setopts(Sock, [{packet, raw}]),
            PumpB = spawn(ace_tunnel, pump, [Sock, PublicSock]),
            gen_tcp:controlling_process(Sock, PumpB),
            ok;
        {broker, drop} ->
            gen_tcp:close(Sock)
    after 15000 ->
        gen_tcp:close(Sock)
    end.

%% ---- gen_server (the broker) ----

init([Key]) ->
    {ok, #state{key = Key}}.

handle_cast({hello, HPid, Sock, Name, Nonce, Mac}, State = #state{key = Key}) ->
    Expect = ace_tunnel:hmac_hex(Key, ["hello:", Nonce, ":", Name]),
    case Mac =:= Expect of
        true ->
            gen_tcp:send(Sock, "OK\n"),
            Broker = self(),
            Watcher = spawn(fun() -> control_watcher(Sock, Broker) end),
            HPid ! {broker, {control, Watcher}},
            io:format("ace_relay: agent registered: ~s~n", [Name]),
            {noreply, State#state{control = {Sock, Watcher}}};
        false ->
            gen_tcp:send(Sock, "ERR auth\n"),
            HPid ! {broker, drop},
            io:format("ace_relay: agent auth REFUSED for ~s~n", [Name]),
            {noreply, State}
    end;

handle_cast({stream, HPid, Sock, Id, Mac}, State = #state{key = Key, pending = Pending}) ->
    Expect = ace_tunnel:hmac_hex(Key, ["stream:", Id]),
    case {Mac =:= Expect, maps:find(Id, Pending)} of
        {true, {ok, PublicSock}} ->
            gen_tcp:send(Sock, "GO\n"),
            inet:setopts(PublicSock, [{packet, raw}]),
            PumpA = spawn(ace_tunnel, pump, [PublicSock, Sock]),
            gen_tcp:controlling_process(PublicSock, PumpA),
            HPid ! {broker, {pair, PublicSock}},
            {noreply, State#state{pending = maps:remove(Id, Pending)}};
        _ ->
            HPid ! {broker, drop},
            {noreply, State}
    end;

handle_cast({public_conn, Sock}, State = #state{control = Control, pending = Pending}) ->
    case Control of
        undefined ->
            gen_tcp:close(Sock),
            {noreply, State};
        {ControlSock, _Watcher} ->
            Id = ace_tunnel:nonce_hex(),
            gen_tcp:send(ControlSock, "OPEN " ++ Id ++ "\n"),
            erlang:send_after(15000, self(), {stream_timeout, Id}),
            {noreply, State#state{pending = Pending#{Id => Sock}}}
    end;

handle_cast({control_down}, State) ->
    io:format("ace_relay: agent control connection lost~n"),
    {noreply, State#state{control = undefined}};

handle_cast(_Other, State) ->
    {noreply, State}.

handle_info({stream_timeout, Id}, State = #state{pending = Pending}) ->
    case maps:find(Id, Pending) of
        {ok, Sock} -> gen_tcp:close(Sock);
        error -> ok
    end,
    {noreply, State#state{pending = maps:remove(Id, Pending)}};
handle_info(_Info, State) ->
    {noreply, State}.

handle_call(_Req, _From, State) -> {reply, ok, State}.
terminate(_Reason, _State) -> ok.
code_change(_Old, State, _Extra) -> {ok, State}.

%% Owns the registered control socket: notices the agent going away.
%% The broker sends OPEN lines on this socket; sending is not gated by
%% ownership, receiving and close detection are.
control_watcher(Sock, Broker) ->
    case gen_tcp:recv(Sock, 0) of
        {error, _} -> gen_server:cast(Broker, {control_down});
        {ok, _Junk} -> control_watcher(Sock, Broker)
    end.
