(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Asm.mli *)

type arch = Arm | Arm64
type name = { sym : string; static : bool }
type base = R of int | SB | FP | SP | PC
type shift_kind = Lsl | Lsr | Asr | Ror
type shift = { reg : int; kind : shift_kind; by : [ `Imm of int | `Reg of int ] }
type mem = { base : base; name : name option; off : int64; index : shift option }

type operand =
  | Reg of int
  | FReg of int
  | Special of string
  | Imm of int64
  | Fimm of float
  | Str of string
  | Mem of mem
  | Addr of mem
  | Shifted of shift
  | Regs of int list
  | Pair of int * int
  | Target of int

type instr = { op : string; suffixes : string list; args : operand list }

type item =
  | Text of name * int * int64
  | Globl of name * int * int64
  | Data of name * int64 * int * operand
  | Ins of instr

type obj = { arch : arch; file : string; items : (item * int) array }

let register arch s =
  let num prefix =
    let n = String.length prefix in
    if String.length s > n && String.sub s 0 n = prefix then int_of_string_opt (String.sub s n (String.length s - n))
    else None
  in
  match arch, s with
  | Arm, "SP" -> Some (Reg 13)
  | Arm, "PC" -> Some (Reg 15)
  | Arm64, ("ZR" | "RSP") -> Some (Reg 31)
  | Arm64, "LR" -> Some (Reg 30)
  | _, ("CPSR" | "SPSR" | "FPSR" | "FPCR") -> Some (Special s)
  | _ -> (
      let max = match arch with Arm -> 15 | Arm64 -> 31 in
      match num "R", num "F" with
      | Some r, _ when r >= 0 && r <= max -> Some (Reg r)
      | _, Some f when f >= 0 && f <= 31 -> Some (FReg f)
      | _ -> None)

(* the objects: marshalled, with a version, as xix's *)
let version = 2

let read_file (caps : < Cap.open_in; .. >) file =
  let ic = CapStdlib.open_in caps file in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

let write_file (_ : < Cap.open_out; .. >) ?(perm = 0o644) file s =
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm file (fun oc -> Out_channel.output_string oc s)

let save caps file (o : obj) = write_file caps file (Marshal.to_string (version, o) [])

let load caps file : obj =
  let v, (o : obj) = Marshal.from_string (read_file caps file) 0 in
  if v <> version then failwith (file ^ ": an object of another version");
  o

let show_name (n : name) = if n.static then n.sym ^ "<>" else n.sym

let show_shift (s : shift) =
  Printf.sprintf "R%d%s%s" s.reg (match s.kind with Lsl -> "<<" | Lsr -> ">>" | Asr -> "->" | Ror -> "@>")
    (match s.by with `Imm n -> string_of_int n | `Reg r -> Printf.sprintf "R%d" r)

let show_mem (m : mem) =
  let off = if m.off = 0L then "" else if m.off > 0L && m.name <> None then "+" ^ Int64.to_string m.off else Int64.to_string m.off in
  let base = match m.base with R r -> Printf.sprintf "(R%d)" r | SB -> "(SB)" | FP -> "(FP)" | SP -> "(SP)" | PC -> "(PC)" in
  let prefix = match m.index with Some s -> show_shift s | None -> "" in
  match m.name with
  | Some n -> Printf.sprintf "%s%s%s" (show_name n) (if off = "" then "+0" else off) base
  | None -> Printf.sprintf "%s%s%s" prefix (if off = "" then "0" else off) base

let show_operand = function
  | Reg r -> Printf.sprintf "R%d" r
  | FReg f -> Printf.sprintf "F%d" f
  | Special s -> s
  | Imm n -> "$" ^ Int64.to_string n
  | Fimm x -> Printf.sprintf "$%h" x
  | Str s -> Printf.sprintf "$%S" s
  | Mem m -> show_mem m
  | Addr m -> "$" ^ show_mem m
  | Shifted s -> show_shift s
  | Regs rs -> "[" ^ String.concat "," (List.map (Printf.sprintf "R%d") rs) ^ "]"
  | Pair (a, b) -> Printf.sprintf "(R%d, R%d)" a b
  | Target i -> Printf.sprintf "#%d" i

let show_item = function
  | Text (n, flag, frame) -> Printf.sprintf "TEXT %s(SB), %d, $%Ld" (show_name n) flag frame
  | Globl (n, flag, size) -> Printf.sprintf "GLOBL %s(SB), %d, $%Ld" (show_name n) flag size
  | Data (n, off, w, v) -> Printf.sprintf "DATA %s+%Ld(SB)/%d, %s" (show_name n) off w (show_operand v)
  | Ins i ->
      String.concat "." (i.op :: i.suffixes) ^ (if i.args = [] then "" else " ")
      ^ String.concat ", " (List.map show_operand i.args)
