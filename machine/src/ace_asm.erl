%% ace_asm — a small two-pass assembler for ace6502 programs, written
%% in program terms rather than text:
%%   {label, Name}
%%   {Mnemonic, imp | acc | {imm, V} | {zp, V} | {zpx, V} | {zpy, V}
%%                    | {abs, V | Label} | {abx, V} | {aby, V}
%%                    | {ind, V | Label} | {izx, V} | {izy, V} | {rel, Label}}
%%   {bytes, [Byte, ...]}
%% Opcode bytes come from ace6502's own table, inverted — the assembler
%% and the machine can never disagree about the encoding.
-module(ace_asm).
-export([assemble/2]).

assemble(Terms, Org) ->
    Table = table(),
    case pass1(Terms, Org, #{}) of
        {ok, Labels} ->
            case emit(Terms, Org, Labels, Table, []) of
                {ok, Bytes} -> {ok, list_to_binary(lists:reverse(Bytes)), Labels};
                Error -> Error
            end;
        Error -> Error
    end.

table() ->
    lists:foldl(fun(Op, Acc) ->
        case ace6502:opcode_info(Op) of
            illegal -> Acc;
            {Instr, Mode} -> Acc#{{Instr, Mode} => Op}
        end
    end, #{}, lists:seq(0, 255)).

mode_size(imp) -> 1;
mode_size(acc) -> 1;
mode_size({imm, _}) -> 2;
mode_size({zp, _}) -> 2;
mode_size({zpx, _}) -> 2;
mode_size({zpy, _}) -> 2;
mode_size({izx, _}) -> 2;
mode_size({izy, _}) -> 2;
mode_size({rel, _}) -> 2;
mode_size({abs, _}) -> 3;
mode_size({abx, _}) -> 3;
mode_size({aby, _}) -> 3;
mode_size({ind, _}) -> 3.

mode_of(imp) -> imp;
mode_of(acc) -> acc;
mode_of({M, _}) -> M.

pass1([], _Addr, Labels) -> {ok, Labels};
pass1([{label, Name} | Rest], Addr, Labels) ->
    pass1(Rest, Addr, Labels#{Name => Addr});
pass1([{bytes, Bs} | Rest], Addr, Labels) ->
    pass1(Rest, Addr + length(Bs), Labels);
pass1([{_Instr, ModeArg} | Rest], Addr, Labels) ->
    pass1(Rest, Addr + mode_size(ModeArg), Labels).

emit([], _Addr, _Labels, _Table, Acc) -> {ok, Acc};
emit([{label, _} | Rest], Addr, Labels, Table, Acc) ->
    emit(Rest, Addr, Labels, Table, Acc);
emit([{bytes, Bs} | Rest], Addr, Labels, Table, Acc) ->
    emit(Rest, Addr + length(Bs), Labels, Table, lists:reverse(Bs) ++ Acc);
emit([{Instr0, ModeArg} | Rest], Addr, Labels, Table, Acc) ->
    Instr = normalize(Instr0),
    Mode = mode_of(ModeArg),
    case maps:find({Instr, Mode}, Table) of
        error ->
            {error, {no_opcode, Instr, Mode}};
        {ok, Op} ->
            case operand(ModeArg, Addr, Labels) of
                {ok, Bytes} ->
                    emit(Rest, Addr + mode_size(ModeArg), Labels, Table,
                         lists:reverse([Op | Bytes]) ++ Acc);
                Error -> Error
            end
    end.

normalize('and') -> and_;
normalize(I) -> I.

operand(imp, _Addr, _Labels) -> {ok, []};
operand(acc, _Addr, _Labels) -> {ok, []};
operand({imm, V}, _Addr, _Labels) -> {ok, [V band 16#FF]};
operand({zp, V}, _Addr, _Labels) -> {ok, [V band 16#FF]};
operand({zpx, V}, _Addr, _Labels) -> {ok, [V band 16#FF]};
operand({zpy, V}, _Addr, _Labels) -> {ok, [V band 16#FF]};
operand({izx, V}, _Addr, _Labels) -> {ok, [V band 16#FF]};
operand({izy, V}, _Addr, _Labels) -> {ok, [V band 16#FF]};
operand({rel, Target}, Addr, Labels) ->
    case resolve(Target, Labels) of
        {ok, T} ->
            Off = T - (Addr + 2),
            if Off >= -128 andalso Off =< 127 -> {ok, [Off band 16#FF]};
               true -> {error, {branch_out_of_range, Target, Off}}
            end;
        Error -> Error
    end;
operand({abs, V}, _Addr, Labels) -> word(V, Labels);
operand({abx, V}, _Addr, Labels) -> word(V, Labels);
operand({aby, V}, _Addr, Labels) -> word(V, Labels);
operand({ind, V}, _Addr, Labels) -> word(V, Labels).

word(V, _Labels) when is_integer(V) -> {ok, [V band 16#FF, (V bsr 8) band 16#FF]};
word(Label, Labels) ->
    case resolve(Label, Labels) of
        {ok, T} -> {ok, [T band 16#FF, (T bsr 8) band 16#FF]};
        Error -> Error
    end.

resolve(V, _Labels) when is_integer(V) -> {ok, V};
resolve(Name, Labels) ->
    case maps:find(Name, Labels) of
        {ok, Addr} -> {ok, Addr};
        error -> {error, {unknown_label, Name}}
    end.
