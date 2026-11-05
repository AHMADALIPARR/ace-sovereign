%% ace6502 — a 6502 virtual machine in Erlang: the container CPU of the
%% sovereign ACE. A sandbox program is a 6502 binary; the machine is a
%% BEAM-side functional state (64 KB memory in an array, registers and
%% flags as fields), so it runs identically on any hardware BEAM runs
%% on — no KVM, no QEMU, no architecture port. Isolation is the memory
%% map: the program can touch only its own 64 KB, and its only channel
%% out is a memory-mapped port.
%%
%% Container semantics (divergences from silicon, deliberate):
%%   * BRK halts the machine (there are no interrupt vectors in a
%%     container). RTI still executes as an instruction.
%%   * Writes to $FE00 append a byte to the machine's output.
%%     Reads from $FE01 return 0 (no input device attached).
%%   * Execution is bounded by a step budget; a program that does not
%%     halt within it is stopped deterministically.
%%   * Cycle counts are not modelled; steps are the unit.
%% The NMOS JMP-indirect page-boundary quirk IS modelled.
-module(ace6502).
-export([load/2, from_image/1, run/2, step/1, output/1, read_mem/2,
         registers/1, opcode_info/1, run_binary/3]).

-record(m, {a = 0, x = 0, y = 0, sp = 16#FF, pc = 0,
            n = 0, z = 0, c = 0, v = 0, d = 0, i = 1,
            mem, out = [], steps = 0, halted = undefined}).

-define(OUT_PORT, 16#FE00).
-define(IN_PORT, 16#FE01).

%% ---- construction ----

%% load(Bytes, Org): fresh memory, Bytes placed at Org, pc = Org.
load(Bytes, Org) when is_binary(Bytes) ->
    Mem = write_bytes(array:new(65536, {default, 0}), Org, binary_to_list(Bytes)),
    #m{mem = Mem, pc = Org}.

%% from_image(Bin64K): a full memory image; pc from the reset vector.
from_image(Bin) when byte_size(Bin) =:= 65536 ->
    Mem = write_bytes(array:new(65536, {default, 0}), 0, binary_to_list(Bin)),
    Pc = array:get(16#FFFC, Mem) bor (array:get(16#FFFD, Mem) bsl 8),
    #m{mem = Mem, pc = Pc}.

write_bytes(Mem, _Addr, []) -> Mem;
write_bytes(Mem, Addr, [B | Rest]) ->
    write_bytes(array:set(Addr band 16#FFFF, B band 16#FF, Mem), Addr + 1, Rest).

%% run_binary(Bytes, Org, Budget) -> {ok, Output, State}
%%                                  | {error, Reason, Output, State}
run_binary(Bytes, Org, Budget) ->
    run(load(Bytes, Org), Budget).

run(M = #m{halted = undefined}, Budget) when Budget > 0 ->
    run(step(M), Budget - 1);
run(M = #m{halted = undefined}, _Budget) ->
    {error, budget_exhausted, output(M), M};
run(M = #m{halted = brk}, _Budget) ->
    {ok, output(M), M};
run(M = #m{halted = Reason}, _Budget) ->
    {error, Reason, output(M), M}.

output(#m{out = Out}) -> list_to_binary(lists:reverse(Out)).

read_mem(#m{mem = Mem}, Addr) -> array:get(Addr band 16#FFFF, Mem).

registers(#m{a = A, x = X, y = Y, sp = SP, pc = PC, steps = Steps}) ->
    #{a => A, x => X, y => Y, sp => SP, pc => PC, steps => Steps}.

%% ---- memory ----

rd(#m{}, Addr) when Addr =:= ?IN_PORT -> 0;
rd(#m{mem = Mem}, Addr) -> array:get(Addr band 16#FFFF, Mem).

wr(M = #m{mem = Mem, out = Out}, Addr, Val) ->
    M2 = M#m{mem = array:set(Addr band 16#FFFF, Val band 16#FF, Mem)},
    case Addr of
        ?OUT_PORT -> M2#m{out = [Val band 16#FF | Out]};
        _ -> M2
    end.

%% ---- the step ----

step(M0 = #m{pc = PC}) ->
    Op = rd(M0, PC),
    case opcode_info(Op) of
        illegal ->
            M0#m{halted = {illegal_opcode, Op, PC}};
        {Instr, Mode} ->
            M1 = M0#m{pc = (PC + 1) band 16#FFFF, steps = M0#m.steps + 1},
            exec(Instr, Mode, M1)
    end.

%% Effective address (and operand value) per addressing mode. Returns
%% {addr, M} or {value, M} for imm/acc handled inline by exec.
addr(imm, M = #m{pc = PC}) -> {PC, M#m{pc = (PC + 1) band 16#FFFF}};
addr(zp, M) -> {rd(M, M#m.pc), advance(M)};
addr(zpx, M = #m{x = X}) -> {(rd(M, M#m.pc) + X) band 16#FF, advance(M)};
addr(zpy, M = #m{y = Y}) -> {(rd(M, M#m.pc) + Y) band 16#FF, advance(M)};
addr(abs, M = #m{pc = PC}) ->
    {rd(M, PC) bor (rd(M, PC + 1) bsl 8), advance2(M)};
addr(abx, M = #m{x = X}) ->
    Base = rd(M, M#m.pc) bor (rd(M, M#m.pc + 1) bsl 8),
    {(Base + X) band 16#FFFF, advance2(M)};
addr(aby, M = #m{y = Y}) ->
    Base = rd(M, M#m.pc) bor (rd(M, M#m.pc + 1) bsl 8),
    {(Base + Y) band 16#FFFF, advance2(M)};
addr(ind, M = #m{pc = PC}) ->
    Ptr = rd(M, PC) bor (rd(M, PC + 1) bsl 8),
    Lo = rd(M, Ptr),
    HiAddr = (Ptr band 16#FF00) bor ((Ptr + 1) band 16#FF),  %% NMOS quirk
    {Lo bor (rd(M, HiAddr) bsl 8), advance2(M)};
addr(izx, M = #m{x = X}) ->
    Zp = (rd(M, M#m.pc) + X) band 16#FF,
    {rd(M, Zp) bor (rd(M, (Zp + 1) band 16#FF) bsl 8), advance(M)};
addr(izy, M = #m{y = Y}) ->
    Zp = rd(M, M#m.pc),
    Base = rd(M, Zp) bor (rd(M, (Zp + 1) band 16#FF) bsl 8),
    {(Base + Y) band 16#FFFF, advance(M)}.

advance(M = #m{pc = PC}) -> M#m{pc = (PC + 1) band 16#FFFF}.
advance2(M = #m{pc = PC}) -> M#m{pc = (PC + 2) band 16#FFFF}.

val(Mode, M) ->
    case Mode of
        acc -> {M#m.a, M};
        _ -> {Addr, M2} = addr(Mode, M), {rd(M2, Addr), M2}
    end.

%% ---- flags ----

nz(M, V) -> M#m{n = (V bsr 7) band 1, z = flag(V =:= 0)}.
flag(true) -> 1; flag(false) -> 0.

flags_byte(#m{n = N, v = V, d = D, i = I, z = Z, c = C}, Break) ->
    (N bsl 7) bor (V bsl 6) bor (1 bsl 5) bor (Break bsl 4) bor
    (D bsl 3) bor (I bsl 2) bor (Z bsl 1) bor C.

set_flags(M, B) ->
    M#m{n = (B bsr 7) band 1, v = (B bsr 6) band 1, d = (B bsr 3) band 1,
        i = (B bsr 2) band 1, z = (B bsr 1) band 1, c = B band 1}.

push(M0, Val) ->
    M1 = wr(M0, 16#0100 + M0#m.sp, Val),
    M1#m{sp = (M0#m.sp - 1) band 16#FF}.

pull(M0) ->
    Sp = (M0#m.sp + 1) band 16#FF,
    {rd(M0, 16#0100 + Sp), M0#m{sp = Sp}}.

%% ---- exec: one clause family per instruction ----

exec(brk, _Mode, M) -> M#m{halted = brk};
exec(nop, _Mode, M) -> M;
exec(pha, _, M) -> push(M, M#m.a);
exec(php, _, M) -> push(M, flags_byte(M, 1));
exec(pla, _, M0) -> {V, M1} = pull(M0), nz(M1#m{a = V}, V);
exec(plp, _, M0) -> {V, M1} = pull(M0), set_flags(M1, V);

exec(clc, _, M) -> M#m{c = 0};
exec(sec, _, M) -> M#m{c = 1};
exec(cli, _, M) -> M#m{i = 0};
exec(sei, _, M) -> M#m{i = 1};
exec(clv, _, M) -> M#m{v = 0};
exec(cld, _, M) -> M#m{d = 0};
exec(sed, _, M) -> M#m{d = 1};

exec(tax, _, M) -> nz(M#m{x = M#m.a}, M#m.a);
exec(tay, _, M) -> nz(M#m{y = M#m.a}, M#m.a);
exec(txa, _, M) -> nz(M#m{a = M#m.x}, M#m.x);
exec(tya, _, M) -> nz(M#m{a = M#m.y}, M#m.y);
exec(tsx, _, M) -> nz(M#m{x = M#m.sp}, M#m.sp);
exec(txs, _, M) -> M#m{sp = M#m.x};
exec(inx, _, M) -> V = (M#m.x + 1) band 16#FF, nz(M#m{x = V}, V);
exec(iny, _, M) -> V = (M#m.y + 1) band 16#FF, nz(M#m{y = V}, V);
exec(dex, _, M) -> V = (M#m.x - 1) band 16#FF, nz(M#m{x = V}, V);
exec(dey, _, M) -> V = (M#m.y - 1) band 16#FF, nz(M#m{y = V}, V);

exec(lda, Mode, M0) -> {V, M1} = val(Mode, M0), nz(M1#m{a = V}, V);
exec(ldx, Mode, M0) -> {V, M1} = val(Mode, M0), nz(M1#m{x = V}, V);
exec(ldy, Mode, M0) -> {V, M1} = val(Mode, M0), nz(M1#m{y = V}, V);
exec(sta, Mode, M0) -> {Addr, M1} = addr(Mode, M0), wr(M1, Addr, M0#m.a);
exec(stx, Mode, M0) -> {Addr, M1} = addr(Mode, M0), wr(M1, Addr, M0#m.x);
exec(sty, Mode, M0) -> {Addr, M1} = addr(Mode, M0), wr(M1, Addr, M0#m.y);

exec(ora, Mode, M0) -> {V, M1} = val(Mode, M0), R = M1#m.a bor V, nz(M1#m{a = R}, R);
exec(and_, Mode, M0) -> {V, M1} = val(Mode, M0), R = M1#m.a band V, nz(M1#m{a = R}, R);
exec(eor, Mode, M0) -> {V, M1} = val(Mode, M0), R = M1#m.a bxor V, nz(M1#m{a = R}, R);
exec(bit, Mode, M0) ->
    {V, M1} = val(Mode, M0),
    M1#m{z = flag((M1#m.a band V) =:= 0), n = (V bsr 7) band 1, v = (V bsr 6) band 1};

exec(adc, Mode, M0) -> {V, M1} = val(Mode, M0), adc(M1, V);
exec(sbc, Mode, M0) -> {V, M1} = val(Mode, M0), sbc(M1, V);

exec(cmp, Mode, M0) -> {V, M1} = val(Mode, M0), compare(M1, M1#m.a, V);
exec(cpx, Mode, M0) -> {V, M1} = val(Mode, M0), compare(M1, M1#m.x, V);
exec(cpy, Mode, M0) -> {V, M1} = val(Mode, M0), compare(M1, M1#m.y, V);

exec(inc, Mode, M0) ->
    {Addr, M1} = addr(Mode, M0), V = (rd(M1, Addr) + 1) band 16#FF,
    nz(wr(M1, Addr, V), V);
exec(dec, Mode, M0) ->
    {Addr, M1} = addr(Mode, M0), V = (rd(M1, Addr) - 1) band 16#FF,
    nz(wr(M1, Addr, V), V);

exec(asl, Mode, M) -> shift(Mode, M, fun(V, _C) -> {(V bsl 1) band 16#FF, (V bsr 7) band 1} end);
exec(lsr, Mode, M) -> shift(Mode, M, fun(V, _C) -> {V bsr 1, V band 1} end);
exec(rol, Mode, M) -> shift(Mode, M, fun(V, C) -> {((V bsl 1) bor C) band 16#FF, (V bsr 7) band 1} end);
exec(ror, Mode, M) -> shift(Mode, M, fun(V, C) -> {(V bsr 1) bor (C bsl 7), V band 1} end);

exec(jmp, Mode, M0) -> {Target, M1} = addr(Mode, M0), M1#m{pc = Target};
exec(jsr, _Mode, M0 = #m{pc = PC}) ->
    {Target, M1} = addr(abs, M0),
    Ret = (PC + 1) band 16#FFFF,
    M2 = push(M1, (Ret bsr 8) band 16#FF),
    M3 = push(M2, Ret band 16#FF),
    M3#m{pc = Target};
exec(rts, _, M0) ->
    {Lo, M1} = pull(M0), {Hi, M2} = pull(M1),
    M2#m{pc = ((Lo bor (Hi bsl 8)) + 1) band 16#FFFF};
exec(rti, _, M0) ->
    {F, M1} = pull(M0), M2 = set_flags(M1, F),
    {Lo, M3} = pull(M2), {Hi, M4} = pull(M3),
    M4#m{pc = Lo bor (Hi bsl 8)};

exec(bpl, _, M) -> branch(M, M#m.n =:= 0);
exec(bmi, _, M) -> branch(M, M#m.n =:= 1);
exec(bvc, _, M) -> branch(M, M#m.v =:= 0);
exec(bvs, _, M) -> branch(M, M#m.v =:= 1);
exec(bcc, _, M) -> branch(M, M#m.c =:= 0);
exec(bcs, _, M) -> branch(M, M#m.c =:= 1);
exec(bne, _, M) -> branch(M, M#m.z =:= 0);
exec(beq, _, M) -> branch(M, M#m.z =:= 1).

branch(M0 = #m{pc = PC}, Taken) ->
    OffsetByte = rd(M0, PC),
    M1 = M0#m{pc = (PC + 1) band 16#FFFF},
    case Taken of
        false -> M1;
        true ->
            Signed = if OffsetByte >= 128 -> OffsetByte - 256; true -> OffsetByte end,
            M1#m{pc = (M1#m.pc + Signed) band 16#FFFF}
    end.

compare(M, Reg, V) ->
    T = (Reg - V) band 16#FF,
    M#m{c = flag(Reg >= V), z = flag(T =:= 0), n = (T bsr 7) band 1}.

shift(acc, M, F) ->
    {R, C} = F(M#m.a, M#m.c),
    nz(M#m{a = R, c = C}, R);
shift(Mode, M0, F) ->
    {Addr, M1} = addr(Mode, M0),
    {R, C} = F(rd(M1, Addr), M1#m.c),
    nz(wr(M1#m{c = C}, Addr, R), R).

%% ---- arithmetic, binary and BCD ----

adc(M = #m{a = A, c = C, d = 0}, V) ->
    Sum = A + V + C,
    R = Sum band 16#FF,
    M#m{a = R, c = flag(Sum > 16#FF), z = flag(R =:= 0), n = (R bsr 7) band 1,
        v = flag(((A bxor R) band (V bxor R) band 16#80) =/= 0)};
adc(M = #m{a = A, c = C, d = 1}, V) ->
    Bin = A + V + C,
    Lo = (A band 16#0F) + (V band 16#0F) + C,
    {Lo2, HiCarry} = if Lo > 9 -> {Lo + 6, 1}; true -> {Lo, 0} end,
    Hi = (A bsr 4) + (V bsr 4) + HiCarry,
    {Hi2, C2} = if Hi > 9 -> {Hi + 6, 1}; true -> {Hi, 0} end,
    R = ((Hi2 band 16#0F) bsl 4) bor (Lo2 band 16#0F),
    BinR = Bin band 16#FF,
    M#m{a = R, c = C2, z = flag(R =:= 0), n = (R bsr 7) band 1,
        v = flag(((A bxor BinR) band (V bxor BinR) band 16#80) =/= 0)}.

sbc(M = #m{a = A, c = C, d = 0}, V) ->
    Diff = A - V - (1 - C),
    R = Diff band 16#FF,
    M#m{a = R, c = flag(Diff >= 0), z = flag(R =:= 0), n = (R bsr 7) band 1,
        v = flag(((A bxor R) band ((bnot V) bxor R) band 16#80) =/= 0)};
sbc(M = #m{a = A, c = C, d = 1}, V) ->
    Bin = A - V - (1 - C),
    Lo = (A band 16#0F) - (V band 16#0F) - (1 - C),
    {Lo2, HiBorrow} = if Lo < 0 -> {Lo - 6, 1}; true -> {Lo, 0} end,
    Hi = (A bsr 4) - (V bsr 4) - HiBorrow,
    {Hi2, C2} = if Hi < 0 -> {Hi - 6, 0}; true -> {Hi, 1} end,
    R = ((Hi2 band 16#0F) bsl 4) bor (Lo2 band 16#0F),
    BinR = Bin band 16#FF,
    M#m{a = R, c = C2, z = flag(R =:= 0), n = (R bsr 7) band 1,
        v = flag(((A bxor BinR) band ((bnot V) bxor BinR) band 16#80) =/= 0)}.

%% ---- the opcode table: the full official NMOS 6502 set ----

opcode_info(16#00) -> {brk, imp};   opcode_info(16#01) -> {ora, izx};
opcode_info(16#05) -> {ora, zp};    opcode_info(16#06) -> {asl, zp};
opcode_info(16#08) -> {php, imp};   opcode_info(16#09) -> {ora, imm};
opcode_info(16#0A) -> {asl, acc};   opcode_info(16#0D) -> {ora, abs};
opcode_info(16#0E) -> {asl, abs};
opcode_info(16#10) -> {bpl, rel};   opcode_info(16#11) -> {ora, izy};
opcode_info(16#15) -> {ora, zpx};   opcode_info(16#16) -> {asl, zpx};
opcode_info(16#18) -> {clc, imp};   opcode_info(16#19) -> {ora, aby};
opcode_info(16#1D) -> {ora, abx};   opcode_info(16#1E) -> {asl, abx};
opcode_info(16#20) -> {jsr, abs};   opcode_info(16#21) -> {and_, izx};
opcode_info(16#24) -> {bit, zp};    opcode_info(16#25) -> {and_, zp};
opcode_info(16#26) -> {rol, zp};    opcode_info(16#28) -> {plp, imp};
opcode_info(16#29) -> {and_, imm};  opcode_info(16#2A) -> {rol, acc};
opcode_info(16#2C) -> {bit, abs};   opcode_info(16#2D) -> {and_, abs};
opcode_info(16#2E) -> {rol, abs};
opcode_info(16#30) -> {bmi, rel};   opcode_info(16#31) -> {and_, izy};
opcode_info(16#35) -> {and_, zpx};  opcode_info(16#36) -> {rol, zpx};
opcode_info(16#38) -> {sec, imp};   opcode_info(16#39) -> {and_, aby};
opcode_info(16#3D) -> {and_, abx};  opcode_info(16#3E) -> {rol, abx};
opcode_info(16#40) -> {rti, imp};   opcode_info(16#41) -> {eor, izx};
opcode_info(16#45) -> {eor, zp};    opcode_info(16#46) -> {lsr, zp};
opcode_info(16#48) -> {pha, imp};   opcode_info(16#49) -> {eor, imm};
opcode_info(16#4A) -> {lsr, acc};   opcode_info(16#4C) -> {jmp, abs};
opcode_info(16#4D) -> {eor, abs};   opcode_info(16#4E) -> {lsr, abs};
opcode_info(16#50) -> {bvc, rel};   opcode_info(16#51) -> {eor, izy};
opcode_info(16#55) -> {eor, zpx};   opcode_info(16#56) -> {lsr, zpx};
opcode_info(16#58) -> {cli, imp};   opcode_info(16#59) -> {eor, aby};
opcode_info(16#5D) -> {eor, abx};   opcode_info(16#5E) -> {lsr, abx};
opcode_info(16#60) -> {rts, imp};   opcode_info(16#61) -> {adc, izx};
opcode_info(16#65) -> {adc, zp};    opcode_info(16#66) -> {ror, zp};
opcode_info(16#68) -> {pla, imp};   opcode_info(16#69) -> {adc, imm};
opcode_info(16#6A) -> {ror, acc};   opcode_info(16#6C) -> {jmp, ind};
opcode_info(16#6D) -> {adc, abs};   opcode_info(16#6E) -> {ror, abs};
opcode_info(16#70) -> {bvs, rel};   opcode_info(16#71) -> {adc, izy};
opcode_info(16#75) -> {adc, zpx};   opcode_info(16#76) -> {ror, zpx};
opcode_info(16#78) -> {sei, imp};   opcode_info(16#79) -> {adc, aby};
opcode_info(16#7D) -> {adc, abx};   opcode_info(16#7E) -> {ror, abx};
opcode_info(16#81) -> {sta, izx};   opcode_info(16#84) -> {sty, zp};
opcode_info(16#85) -> {sta, zp};    opcode_info(16#86) -> {stx, zp};
opcode_info(16#88) -> {dey, imp};   opcode_info(16#8A) -> {txa, imp};
opcode_info(16#8C) -> {sty, abs};   opcode_info(16#8D) -> {sta, abs};
opcode_info(16#8E) -> {stx, abs};
opcode_info(16#90) -> {bcc, rel};   opcode_info(16#91) -> {sta, izy};
opcode_info(16#94) -> {sty, zpx};   opcode_info(16#95) -> {sta, zpx};
opcode_info(16#96) -> {stx, zpy};   opcode_info(16#98) -> {tya, imp};
opcode_info(16#99) -> {sta, aby};   opcode_info(16#9A) -> {txs, imp};
opcode_info(16#9D) -> {sta, abx};
opcode_info(16#A0) -> {ldy, imm};   opcode_info(16#A1) -> {lda, izx};
opcode_info(16#A2) -> {ldx, imm};   opcode_info(16#A4) -> {ldy, zp};
opcode_info(16#A5) -> {lda, zp};    opcode_info(16#A6) -> {ldx, zp};
opcode_info(16#A8) -> {tay, imp};   opcode_info(16#A9) -> {lda, imm};
opcode_info(16#AA) -> {tax, imp};   opcode_info(16#AC) -> {ldy, abs};
opcode_info(16#AD) -> {lda, abs};   opcode_info(16#AE) -> {ldx, abs};
opcode_info(16#B0) -> {bcs, rel};   opcode_info(16#B1) -> {lda, izy};
opcode_info(16#B4) -> {ldy, zpx};   opcode_info(16#B5) -> {lda, zpx};
opcode_info(16#B6) -> {ldx, zpy};   opcode_info(16#B8) -> {clv, imp};
opcode_info(16#B9) -> {lda, aby};   opcode_info(16#BA) -> {tsx, imp};
opcode_info(16#BC) -> {ldy, abx};   opcode_info(16#BD) -> {lda, abx};
opcode_info(16#BE) -> {ldx, aby};
opcode_info(16#C0) -> {cpy, imm};   opcode_info(16#C1) -> {cmp, izx};
opcode_info(16#C4) -> {cpy, zp};    opcode_info(16#C5) -> {cmp, zp};
opcode_info(16#C6) -> {dec, zp};    opcode_info(16#C8) -> {iny, imp};
opcode_info(16#C9) -> {cmp, imm};   opcode_info(16#CA) -> {dex, imp};
opcode_info(16#CC) -> {cpy, abs};   opcode_info(16#CD) -> {cmp, abs};
opcode_info(16#CE) -> {dec, abs};
opcode_info(16#D0) -> {bne, rel};   opcode_info(16#D1) -> {cmp, izy};
opcode_info(16#D5) -> {cmp, zpx};   opcode_info(16#D6) -> {dec, zpx};
opcode_info(16#D8) -> {cld, imp};   opcode_info(16#D9) -> {cmp, aby};
opcode_info(16#DD) -> {cmp, abx};   opcode_info(16#DE) -> {dec, abx};
opcode_info(16#E0) -> {cpx, imm};   opcode_info(16#E1) -> {sbc, izx};
opcode_info(16#E4) -> {cpx, zp};    opcode_info(16#E5) -> {sbc, zp};
opcode_info(16#E6) -> {inc, zp};    opcode_info(16#E8) -> {inx, imp};
opcode_info(16#E9) -> {sbc, imm};   opcode_info(16#EA) -> {nop, imp};
opcode_info(16#EC) -> {cpx, abs};   opcode_info(16#ED) -> {sbc, abs};
opcode_info(16#EE) -> {inc, abs};
opcode_info(16#F0) -> {beq, rel};   opcode_info(16#F1) -> {sbc, izy};
opcode_info(16#F5) -> {sbc, zpx};   opcode_info(16#F6) -> {inc, zpx};
opcode_info(16#F8) -> {sed, imp};   opcode_info(16#F9) -> {sbc, aby};
opcode_info(16#FD) -> {sbc, abx};   opcode_info(16#FE) -> {inc, abx};
opcode_info(_) -> illegal.
