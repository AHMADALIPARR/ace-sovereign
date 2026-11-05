%% ace6502_tests — known-vector tests for the 6502 container machine.
%% Programs are written in ace_asm terms and checked against results
%% computed independently (by hand or in Erlang) — the same standard as
%% the rest of the engine: verified by execution, not asserted.
-module(ace6502_tests).
-export([run_tests/0]).

-define(ORG, 16#0200).

run_tests() ->
    Tests = [fun t_arith/0, fun t_sum_loop/0, fun t_jsr/0, fun t_output/0,
             fun t_budget/0, fun t_bcd/0, fun t_jmp_indirect_quirk/0,
             fun t_sum_squares/0, fun t_illegal/0, fun t_sbc_and_stack/0,
             fun t_indexed_indirect/0],
    lists:foreach(fun(T) -> T() end, Tests),
    io:format("machine: all ~p checks passed~n", [length(Tests)]),
    ok.

check(Name, Got, Want) ->
    case Got =:= Want of
        true -> io:format("ok   - ~s~n", [Name]);
        false ->
            io:format("FAIL - ~s: got ~p, want ~p~n", [Name, Got, Want]),
            erlang:error({test_failed, Name})
    end.

asm(Terms) ->
    {ok, Bin, _Labels} = ace_asm:assemble(Terms, ?ORG),
    Bin.

run_prog(Terms) ->
    ace6502:run_binary(asm(Terms), ?ORG, 100000).

t_arith() ->
    {ok, _Out, M} = run_prog([
        {lda, {imm, 5}}, {clc, imp}, {adc, {imm, 3}},
        {sta, {abs, 16#0300}}, {brk, imp}]),
    check("lda/adc/sta: 5 + 3 stored", ace6502:read_mem(M, 16#0300), 8),
    check("lda/adc: accumulator", maps:get(a, ace6502:registers(M)), 8).

t_sum_loop() ->
    {ok, _Out, M} = run_prog([
        {lda, {imm, 0}}, {sta, {zp, 16#10}},
        {ldx, {imm, 1}}, {stx, {zp, 16#11}},
        {label, loop},
        {lda, {zp, 16#11}}, {clc, imp}, {adc, {zp, 16#10}}, {sta, {zp, 16#10}},
        {inc, {zp, 16#11}},
        {lda, {zp, 16#11}}, {cmp, {imm, 11}}, {bne, {rel, loop}},
        {lda, {zp, 16#10}}, {sta, {abs, 16#0300}}, {brk, imp}]),
    check("loop: sum 1..10 = 55", ace6502:read_mem(M, 16#0300), 55).

t_jsr() ->
    {ok, _Out, M} = run_prog([
        {lda, {imm, 7}}, {jsr, {abs, dbl}}, {sta, {abs, 16#0300}}, {brk, imp},
        {label, dbl}, {asl, acc}, {rts, imp}]),
    check("jsr/rts: 7 doubled = 14", ace6502:read_mem(M, 16#0300), 14).

t_output() ->
    {ok, Out, _M} = run_prog([
        {lda, {imm, $H}}, {sta, {abs, 16#FE00}},
        {lda, {imm, $I}}, {sta, {abs, 16#FE00}},
        {brk, imp}]),
    check("mmio output port: HI", Out, <<"HI">>).

t_budget() ->
    {error, budget_exhausted, _Out, _M} =
        ace6502:run_binary(asm([{label, spin}, {jmp, {abs, spin}}]), ?ORG, 1000),
    check("budget: infinite loop stopped", budget_exhausted, budget_exhausted).

t_bcd() ->
    {ok, _Out, M} = run_prog([
        {sed, imp},
        {lda, {imm, 16#09}}, {clc, imp}, {adc, {imm, 16#01}}, {sta, {abs, 16#0300}},
        {lda, {imm, 16#99}}, {clc, imp}, {adc, {imm, 16#01}}, {sta, {abs, 16#0301}},
        {bcs, {rel, carry}}, {lda, {imm, 0}}, {sta, {abs, 16#0302}}, {brk, imp},
        {label, carry}, {lda, {imm, 1}}, {sta, {abs, 16#0302}}, {brk, imp}]),
    check("bcd: 09 + 01 = 10", ace6502:read_mem(M, 16#0300), 16#10),
    check("bcd: 99 + 01 = 00", ace6502:read_mem(M, 16#0301), 16#00),
    check("bcd: carry set after 99 + 01", ace6502:read_mem(M, 16#0302), 1).

t_jmp_indirect_quirk() ->
    {ok, Setup, _} = ace_asm:assemble([
        {lda, {imm, 16#34}}, {sta, {abs, 16#02FF}},
        {lda, {imm, 16#99}}, {sta, {abs, 16#0200}},
        {lda, {imm, 16#56}}, {sta, {abs, 16#0300}},
        {jmp, {ind, 16#02FF}}], 16#0400),
    {ok, Bugged, _} = ace_asm:assemble(
        [{lda, {imm, 16#42}}, {sta, {abs, 16#0500}}, {brk, imp}], 16#9934),
    {ok, Unbugged, _} = ace_asm:assemble(
        [{lda, {imm, 16#77}}, {sta, {abs, 16#0500}}, {brk, imp}], 16#5634),
    Image = place(place(place(place(zero_image(),
        16#0400, Setup), 16#9934, Bugged), 16#5634, Unbugged),
        16#FFFC, <<16#00, 16#04>>),
    {ok, _Out, M} = ace6502:run(ace6502:from_image(Image), 100000),
    check("jmp indirect: NMOS page quirk lands at $9934",
          ace6502:read_mem(M, 16#0500), 16#42).

zero_image() -> binary:copy(<<0>>, 65536).

place(Image, Org, Bytes) ->
    Size = byte_size(Bytes),
    <<Head:Org/binary, _Old:Size/binary, Tail/binary>> = Image,
    <<Head/binary, Bytes/binary, Tail/binary>>.

t_sum_squares() ->
    {ok, _Out, M} = run_prog([
        {lda, {imm, 0}}, {sta, {zp, 16#10}}, {sta, {zp, 16#11}},
        {lda, {imm, 1}}, {sta, {zp, 16#12}},
        {label, outer},
        {lda, {imm, 0}}, {sta, {zp, 16#13}}, {sta, {zp, 16#14}},
        {lda, {zp, 16#12}}, {sta, {zp, 16#15}},
        {label, inner},
        {lda, {zp, 16#13}}, {clc, imp}, {adc, {zp, 16#12}}, {sta, {zp, 16#13}},
        {lda, {zp, 16#14}}, {adc, {imm, 0}}, {sta, {zp, 16#14}},
        {dec, {zp, 16#15}}, {bne, {rel, inner}},
        {lda, {zp, 16#10}}, {clc, imp}, {adc, {zp, 16#13}}, {sta, {zp, 16#10}},
        {lda, {zp, 16#11}}, {adc, {zp, 16#14}}, {sta, {zp, 16#11}},
        {inc, {zp, 16#12}},
        {lda, {zp, 16#12}}, {cmp, {imm, 13}}, {bne, {rel, outer}},
        {lda, {zp, 16#10}}, {sta, {abs, 16#0300}},
        {lda, {zp, 16#11}}, {sta, {abs, 16#0301}},
        {brk, imp}]),
    Expected = lists:sum([I * I || I <- lists:seq(1, 12)]),
    Got = ace6502:read_mem(M, 16#0300) + 256 * ace6502:read_mem(M, 16#0301),
    check("cross-check: sum of squares 1..12 = 650", Got, Expected).

t_illegal() ->
    {error, {illegal_opcode, 16#02, _Pc}, _Out, _M} =
        ace6502:run_binary(<<16#02>>, ?ORG, 100),
    check("illegal opcode halts with the opcode named", illegal, illegal).

t_sbc_and_stack() ->
    {ok, _Out, M} = run_prog([
        {lda, {imm, 16#10}}, {sec, imp}, {sbc, {imm, 5}}, {sta, {abs, 16#0300}},
        {lda, {imm, 16#77}}, {pha, imp}, {lda, {imm, 0}}, {pla, imp},
        {sta, {abs, 16#0301}}, {brk, imp}]),
    check("sbc: 16 - 5 = 11", ace6502:read_mem(M, 16#0300), 11),
    check("pha/pla round trip", ace6502:read_mem(M, 16#0301), 16#77).

t_indexed_indirect() ->
    {ok, _Out, M} = run_prog([
        {lda, {imm, 16#00}}, {sta, {zp, 16#10}},
        {lda, {imm, 16#03}}, {sta, {zp, 16#11}},
        {lda, {imm, 16#2A}}, {sta, {abs, 16#0303}},
        {ldy, {imm, 3}}, {lda, {izy, 16#10}},
        {sta, {abs, 16#0305}}, {brk, imp}]),
    check("izy: pointer + Y reads through", ace6502:read_mem(M, 16#0305), 16#2A).
