%% ace_harness — the brain's service. Listens on a Unix socket at
%% $SBX_HOME/harness.sock and speaks the protocol in PROTOCOL.md:
%% newline-delimited JSON requests, dispatched via `sbx exec`.
%%
%% The harness decides and dispatches; it never runs the command
%% itself. Every dispatch is written to the sbx hash-chained ledger
%% before execution and after it, under the same chain sbx maintains.
%% Credential-shaped env_allow names are refused here, and refused
%% again inside sbx: the gate exists at both layers on purpose.
-module(ace_harness).
-export([start/0]).

-define(MAX_OUTPUT, 1048576).

cfg(Name, Default) ->
    case os:getenv(Name) of
        false -> Default;
        "" -> Default;
        Value -> Value
    end.

start() ->
    SbxHome = cfg("SBX_HOME", filename:join(os:getenv("HOME"), ".ace-sovereign")),
    Sbx = resolve_sbx(),
    SockPath = filename:join(SbxHome, "harness.sock"),
    file:delete(SockPath),
    {ok, LSock} = gen_tcp:listen(0, [binary, {packet, line}, {active, false},
                                     {ifaddr, {local, SockPath}}]),
    io:format("ace_harness: listening on ~s (sbx: ~s)~n", [SockPath, Sbx]),
    accept_loop(LSock, SbxHome, Sbx).

resolve_sbx() ->
    case os:getenv("ACE_SBX") of
        false ->
            case os:find_executable("sbx") of
                false -> erlang:error(sbx_not_found_set_ACE_SBX);
                Path -> Path
            end;
        Path -> Path
    end.

accept_loop(LSock, SbxHome, Sbx) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            Pid = spawn(fun() ->
                receive {ace_go} -> ok end,
                client_loop(Sock, SbxHome, Sbx)
            end),
            gen_tcp:controlling_process(Sock, Pid),
            Pid ! {ace_go},
            accept_loop(LSock, SbxHome, Sbx);
        {error, closed} -> ok
    end.

client_loop(Sock, SbxHome, Sbx) ->
    case gen_tcp:recv(Sock, 0) of
        {ok, Line} ->
            Response = handle_line(Line, SbxHome, Sbx),
            gen_tcp:send(Sock, [Response, "\n"]),
            client_loop(Sock, SbxHome, Sbx);
        {error, _} ->
            gen_tcp:close(Sock)
    end.

handle_line(Line, SbxHome, Sbx) ->
    case ace_json:decode(Line) of
        {ok, Req} when is_map(Req) ->
            ace_json:encode(dispatch(Req, SbxHome, Sbx));
        _ ->
            ace_json:encode(#{id => null, error => <<"bad_request">>})
    end.

dispatch(Req, SbxHome, Sbx) ->
    Id = maps:get(<<"id">>, Req, null),
    Box = maps:get(<<"box">>, Req, <<"">>),
    Argv = maps:get(<<"argv">>, Req, []),
    Allow = maps:get(<<"env_allow">>, Req, []),
    Timeout = maps:get(<<"timeout_s">>, Req, 600),
    BoxDir = filename:join([SbxHome, "boxes", Box]),
    Refused = [V || V <- Allow, credential_shaped(V)],
    if
        Refused =/= [] ->
            ledger(SbxHome, "dispatch-refused",
                   io_lib:format("box=~s refused=~s", [Box, join_names(Refused)])),
            #{id => Id, error => <<"env_allow_refused">>, refused => Refused};
        not is_list(Argv) orelse Argv =:= [] ->
            #{id => Id, error => <<"bad_argv">>};
        true ->
            case filelib:is_dir(BoxDir) of
                false ->
                    #{id => Id, error => <<"unknown_box">>};
                true ->
                    ledger(SbxHome, "dispatch",
                           io_lib:format("box=~s argv=~s", [Box, join_names(Argv)])),
                    run(Id, SbxHome, Sbx, Box, Argv, Allow, Timeout)
            end
    end.

credential_shaped(Name) ->
    Upper = string:uppercase(binary_to_list(Name)),
    Segments = string:tokens(Upper, "_"),
    lists:any(fun(S) -> lists:member(S, ["TOKEN", "SECRET", "PASSWORD",
                                         "CREDENTIAL", "KEY", "AUTH"]) end,
              Segments).

join_names(Names) ->
    string:join([binary_to_list(N) || N <- Names], " ").

run(Id, SbxHome, Sbx, Box, Argv, Allow, TimeoutS) ->
    AllowArgs = lists:flatmap(fun(V) -> ["--allow", binary_to_list(V)] end, Allow),
    Args = ["exec", binary_to_list(Box)] ++ AllowArgs ++ ["--"] ++
           [binary_to_list(A) || A <- Argv],
    Env = [{"PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
           {"SBX_HOME", SbxHome},
           {"HOME", os:getenv("HOME")}] ++
          [{binary_to_list(V), os:getenv(binary_to_list(V))}
           || V <- Allow, os:getenv(binary_to_list(V)) =/= false],
    Port = open_port({spawn_executable, Sbx},
                     [binary, exit_status, {args, Args}, {env, Env}]),
    Deadline = erlang:monotonic_time(millisecond) + TimeoutS * 1000,
    case collect(Port, <<>>, Deadline) of
        {ok, Exit, Out} ->
            Hash = hex(crypto:hash(sha256, Out)),
            Head = ledger(SbxHome, "dispatch-done",
                          io_lib:format("box=~s exit=~p stdout_sha256=~s",
                                        [Box, Exit, Hash])),
            #{id => Id, exit => Exit, stdout => Out,
              stdout_sha256 => list_to_binary(Hash),
              ledger_head => list_to_binary(Head)};
        timeout ->
            kill_port(Port),
            ledger(SbxHome, "dispatch-done",
                   io_lib:format("box=~s exit=timeout", [Box])),
            #{id => Id, error => <<"timeout">>}
    end.

collect(Port, Acc, Deadline) ->
    Remaining = Deadline - erlang:monotonic_time(millisecond),
    if
        Remaining =< 0 ->
            timeout;
        true ->
            receive
                {Port, {data, Data}} ->
                    Acc2 = <<Acc/binary, Data/binary>>,
                    if
                        byte_size(Acc2) > ?MAX_OUTPUT ->
                            kill_port(Port), {ok, -1, binary:part(Acc2, 0, ?MAX_OUTPUT)};
                        true ->
                            collect(Port, Acc2, Deadline)
                    end;
                {Port, {exit_status, Status}} ->
                    {ok, Status, Acc}
            after Remaining ->
                timeout
            end
    end.

kill_port(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, OsPid} -> os:cmd("kill -9 " ++ integer_to_list(OsPid));
        undefined -> ok
    end,
    port_close(Port),
    ok.

%% ---- the ledger: same chain sbx writes ----
%% line: "<sha256> <iso>|<event>|<details>", hash = sha256(prev|payload).
%% Appends are serialized with a lock directory (mkdir is atomic).

ledger(SbxHome, Event, Details) ->
    LockDir = filename:join(SbxHome, "ledger.lock"),
    acquire(LockDir),
    try
        Path = filename:join(SbxHome, "ledger.log"),
        Prev = last_hash(Path),
        Payload = io_lib:format("~s|~s|~s", [iso_now(), Event, Details]),
        Hash = hex(crypto:hash(sha256, [Prev, "|", Payload])),
        {ok, F} = file:open(Path, [append]),
        io:format(F, "~s ~s~n", [Hash, Payload]),
        file:close(F),
        Hash
    after
        file:del_dir(LockDir)
    end.

acquire(LockDir) -> acquire(LockDir, 200).

acquire(_LockDir, 0) -> erlang:error(ledger_lock_timeout);
acquire(LockDir, N) ->
    case file:make_dir(LockDir) of
        ok -> ok;
        {error, eexist} -> timer:sleep(10), acquire(LockDir, N - 1);
        {error, enoent} -> timer:sleep(10), acquire(LockDir, N - 1)
    end.

last_hash(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>],
            case Lines of
                [] -> lists:duplicate(64, $0);
                _ -> binary_to_list(hd(binary:split(lists:last(Lines), <<" ">>)))
            end;
        {error, enoent} ->
            lists:duplicate(64, $0)
    end.

iso_now() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0wZ", [Y, Mo, D, H, Mi, S]).

hex(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [B]) || B <- binary_to_list(Bin)]).
