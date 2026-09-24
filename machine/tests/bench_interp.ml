(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The speed estimate behind plan_arm.md: a toy interpreter in the
 * style the emulator will have (instructions decoded once into a
 * variant, a register array, one match per instruction, a condition
 * each, a shifter operand, loads and stores, flags), running a loop.
 * 350 million instructions: 75 MIPS on a Neoverse-N1 (2026-09-24), as
 * written, untuned. Build: ocamlfind ocamlopt -package unix -linkpkg
 * bench_interp.ml -o bench_interp *)
type cond = AL | EQ | NE | LT
type op2 = Imm of int | Reg of int | Lsl of int * int
type instr =
  | Add of cond * int * int * op2
  | Sub of cond * int * int * op2 * bool      (* sets flags *)
  | Ldr of cond * int * int * int             (* rd, rn, offset *)
  | Str of cond * int * int * int
  | B of cond * int                           (* absolute target *)
  | Halt

let r = Array.make 16 0
let mem = Bytes.create (1 lsl 20)
let n = ref false and z = ref false

let cond = function AL -> true | EQ -> !z | NE -> not !z | LT -> !n
let op2 = function Imm i -> i | Reg k -> r.(k) | Lsl (k, s) -> (r.(k) lsl s) land 0xffffffff

let run (prog : instr array) =
  let pc = ref 0 and count = ref 0 in
  let continue = ref true in
  while !continue do
    incr count;
    (match prog.(!pc) with
     | Add (c, d, s, o) -> if cond c then r.(d) <- (r.(s) + op2 o) land 0xffffffff; incr pc
     | Sub (c, d, s, o, f) ->
         if cond c then begin
           let v = (r.(s) - op2 o) land 0xffffffff in
           r.(d) <- v;
           if f then (z := v = 0; n := v land 0x80000000 <> 0)
         end;
         incr pc
     | Ldr (c, d, b, off) -> if cond c then r.(d) <- Int32.to_int (Bytes.get_int32_le mem ((r.(b) + off) land 0xffffc)) land 0xffffffff; incr pc
     | Str (c, d, b, off) -> if cond c then Bytes.set_int32_le mem ((r.(b) + off) land 0xffffc) (Int32.of_int r.(d)); incr pc
     | B (c, t) -> if cond c then pc := t else incr pc
     | Halt -> continue := false)
  done;
  !count

(* sum = 0; for i = N downto 1: mem[i%256*4] += i; sum += mem[...] *)
let prog = [|
  Add (AL, 1, 0, Imm 50_000_000);        (* 0: r1 = N *)
  Add (AL, 2, 0, Imm 0);                  (* 1: r2 = 0 (sum) *)
  Add (AL, 3, 1, Lsl (1, 2));             (* 2: r3 = r1 + r1<<2 *)
  Ldr (AL, 4, 3, 0);                      (* 3 *)
  Add (AL, 4, 4, Reg 1);                  (* 4 *)
  Str (AL, 4, 3, 0);                      (* 5 *)
  Add (AL, 2, 2, Reg 4);                  (* 6 *)
  Sub (AL, 1, 1, Imm 1, true);            (* 7: r1--, flags *)
  B (NE, 2);                              (* 8 *)
  Halt |]

let () =
  let t = Unix.gettimeofday () in
  let c = run prog in
  let dt = Unix.gettimeofday () -. t in
  Printf.printf "%d instructions in %.2fs: %.0f MIPS (sum %d)\n" c dt (float c /. dt /. 1e6) r.(2)
