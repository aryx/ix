(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Gas.mli *)

module A = Ix_asm.Asm

let error fmt = Printf.ksprintf failwith fmt
let sprintf = Printf.sprintf

(* a name for GNU's as: a static one (name<>) local, a $ spelled _S *)
let name (n : A.name) =
  let b = Buffer.create 16 in
  String.iter (function '$' -> Buffer.add_string b "_S" | c -> Buffer.add_char b c) n.sym;
  (if n.static then "L_" else "") ^ Buffer.contents b

let reg r = sprintf "r%d" r

(* arm's immediates: 8 bits rotated by an even count *)
let encodable v =
  let v = Int64.to_int v land 0xffffffff in
  List.exists (fun rot -> let x = ((v lsl rot) lor (v lsr (32 - rot))) land 0xffffffff in x < 256) (List.init 16 (fun i -> 2 * i))

let cond suffixes =
  match List.find_opt (fun s -> A.cond_of_string s <> None) suffixes with
  | Some s -> String.lowercase_ascii (A.string_of_cond (Option.get (A.cond_of_string s)))
  | None -> ""

(* R12 the temporary: mini-ld's static base, which mini-ml's code never
 * names *)
let tmp = 12

let ins out labels (i : A.instr) =
  let pr fmt = Printf.ksprintf (fun s -> Buffer.add_string out ("\t" ^ s ^ "\n")) fmt in
  let c = cond i.suffixes in
  let target = function A.Target t -> Hashtbl.replace labels t (); sprintf ".L%d" t | A.Mem { base = SB; name = Some n; _ } -> name n | _ -> error "bad target" in
  (* an offset beyond a load's 12 bits in R12 *)
  let mem = function
    | A.Mem { base = R b; off; name = _; index = None } when Int64.abs off < 4096L -> sprintf "[%s, #%Ld]" (reg b) off
    | A.Mem { base = R b; off; name = _; index = None } -> pr "ldr\t%s, =%Ld" (reg tmp) off; sprintf "[%s, %s]" (reg b) (reg tmp)
    | _ -> error "%s: bad memory" i.op
  in
  (* an operand's value into a register, R12 if it is not one *)
  let value = function
    | A.Reg r -> reg r
    | A.Imm v -> pr "ldr\t%s, =%Ld" (reg tmp) v; reg tmp
    | _ -> error "%s: bad operand" i.op
  in
  let alu op =
    match i.args with
    | [ A.Imm v; A.Reg n; A.Reg d ] when encodable v -> pr "%s%s\t%s, %s, #%Ld" op c (reg d) (reg n) v
    | [ A.Imm v; A.Reg d ] when encodable v -> pr "%s%s\t%s, %s, #%Ld" op c (reg d) (reg d) v
    | [ m; A.Reg n; A.Reg d ] -> let m = value m in pr "%s%s\t%s, %s, %s" op c (reg d) (reg n) m
    | [ m; A.Reg d ] -> let m = value m in pr "%s%s\t%s, %s, %s" op c (reg d) (reg d) m
    | _ -> error "%s: bad operands" i.op
  in
  (* a call of libgcc's division: r0..r3 and lr kept around it *)
  let divide f result =
    let m, n, d =
      match i.args with
      | [ A.Reg m; A.Reg n; A.Reg d ] -> m, n, d
      | [ A.Reg m; A.Reg d ] -> m, d, d
      | _ -> error "%s: bad operands" i.op
    in
    pr "push\t{r0, r1, r2, r3, lr}";
    pr "mov\t%s, %s" (reg tmp) (reg n);
    pr "mov\tr1, %s" (reg m);
    pr "mov\tr0, %s" (reg tmp);
    pr "bl\t%s" f;
    pr "mov\t%s, %s" (reg tmp) result;
    pr "pop\t{r0, r1, r2, r3, lr}";
    pr "mov\t%s, %s" (reg d) (reg tmp)
  in
  match i.op, i.args with
  | ("MOVW" | "MOVBU" | "MOVB" | "MOVH" | "MOVHU"), [ src; dst ] -> (
      let load = match i.op with "MOVBU" -> "ldrb" | "MOVB" -> "ldrsb" | "MOVH" -> "ldrsh" | "MOVHU" -> "ldrh" | _ -> "ldr" in
      let store = match i.op with "MOVBU" | "MOVB" -> "strb" | "MOVH" | "MOVHU" -> "strh" | _ -> "str" in
      match src, dst with
      | A.Reg s, A.Reg d -> pr "mov%s\t%s, %s" c (reg d) (reg s)
      | A.Imm v, A.Reg d when encodable v -> pr "mov%s\t%s, #%Ld" c (reg d) v
      | A.Imm v, A.Reg d when c = "" -> pr "ldr\t%s, =%Ld" (reg d) v
      | A.Addr { base = SB; name = Some n; off; _ }, A.Reg d -> pr "ldr\t%s, =%s+%Ld" (reg d) (name n) off
      | A.Mem { base = SB; name = Some n; off; _ }, A.Reg d -> pr "ldr\t%s, =%s+%Ld" (reg tmp) (name n) off; pr "%s\t%s, [%s]" load (reg d) (reg tmp)
      | A.Reg s, A.Mem { base = SB; name = Some n; off; _ } -> pr "ldr\t%s, =%s+%Ld" (reg tmp) (name n) off; pr "%s\t%s, [%s]" store (reg s) (reg tmp)
      | (A.Mem _ as m), A.Reg d -> pr "%s%s\t%s, %s" load c (reg d) (mem m)
      | A.Reg s, (A.Mem _ as m) -> pr "%s%s\t%s, %s" store c (reg s) (mem m)
      | _ -> error "%s: bad operands" i.op)
  | "ADD", _ -> alu "add"
  | "SUB", _ -> alu "sub"
  | "RSB", _ -> alu "rsb"
  | "AND", _ -> alu "and"
  | "ORR", _ -> alu "orr"
  | "EOR", _ -> alu "eor"
  | "SLL", _ -> alu "lsl"
  | "SRL", _ -> alu "lsr"
  | "SRA", _ -> alu "asr"
  | "MUL", [ A.Reg m; A.Reg n; A.Reg d ] -> pr "mul\t%s, %s, %s" (reg d) (reg n) (reg m)
  | "MVN", [ A.Reg s; A.Reg d ] -> pr "mvn\t%s, %s" (reg d) (reg s)
  | "CMP", [ A.Imm v; A.Reg n ] when encodable v -> pr "cmp\t%s, #%Ld" (reg n) v
  | "CMP", [ m; A.Reg n ] -> let m = value m in pr "cmp\t%s, %s" (reg n) m
  | "DIV", _ -> divide "__aeabi_idiv" "r0"
  | "MOD", _ -> divide "__aeabi_idivmod" "r1"
  | "B", [ A.Mem { base = R r; name = None; _ } ] -> pr "bx%s\t%s" c (reg r)
  | "BL", [ A.Mem { base = R r; name = None; _ } ] -> pr "blx\t%s" (reg r)
  | "BL", [ t ] -> pr "bl\t%s" (target t)
  | "RET", [] -> pr "bx\tlr"
  | op, [ t ] when op.[0] = 'B' -> pr "%s\t%s" (String.lowercase_ascii op) (target t)
  | _ -> error "%s: not in Gas's subset" i.op

let obj (o : A.obj) =
  let out = Buffer.create 65536 and data = Buffer.create 8192 in
  if o.arch <> Arm then error "Gas: arm only";
  Buffer.add_string out "\t.syntax unified\n\t.arm\n\t.text\n";
  (* the branches' targets are labels: known after, so the code's lines
   * each wait for them *)
  let labels = Hashtbl.create 64 in
  let code = Buffer.create 65536 in
  let lines = ref [] and since = ref 0 and pools = ref 0 in
  Array.iteri (fun idx (it, _) ->
    match it with
    | A.Text (n, _, _) ->
        Buffer.clear code;
        if not n.static then Buffer.add_string code (sprintf "\t.globl\t%s\n" (name n));
        Buffer.add_string code (sprintf "\t.align\t2\n%s:\n" (name n));
        lines := (idx, Buffer.contents code) :: !lines
    | Ins i ->
        Buffer.clear code;
        ins code labels i;
        (* the literal pool after an unconditional branch, where it isn't
         * run, and always near its loads *)
        incr since;
        if (i.op = "B" || i.op = "RET") && cond i.suffixes = "" then (Buffer.add_string code "\t.ltorg\n"; since := 0)
        else if !since > 200 then begin
          (* none for long: one here, jumped over *)
          incr pools;
          Buffer.add_string code (sprintf "\tb\t.Lpool%d\n\t.ltorg\n.Lpool%d:\n" !pools !pools);
          since := 0
        end;
        lines := (idx, Buffer.contents code) :: !lines
    | _ -> ()) o.items;
  List.iter (fun (idx, s) -> if Hashtbl.mem labels idx then Buffer.add_string out (sprintf ".L%d:\n" idx); Buffer.add_string out s) (List.rev !lines);
  (* the data: each symbol's words at their offsets, zeros between *)
  let sizes = Hashtbl.create 64 and datas = Hashtbl.create 64 and order = ref [] in
  Array.iter (fun (it, _) ->
    match it with
    | A.Globl (n, _, size) -> if not (Hashtbl.mem sizes n) then order := n :: !order; Hashtbl.replace sizes n (Int64.to_int size)
    | A.Data (n, off, w, v) -> Hashtbl.add datas n (Int64.to_int off, w, v)
    | _ -> ()) o.items;
  Buffer.add_string data "\t.data\n";
  List.iter (fun (n : A.name) ->
    let size = Hashtbl.find sizes n in
    let ds = List.sort compare (Hashtbl.find_all datas n) in
    if ds = [] then Buffer.add_string data (sprintf "\t.%s\t%s, %d, 4\n" (if n.static then "lcomm" else "comm") (name n) size)
    else begin
      if not n.static then Buffer.add_string data (sprintf "\t.globl\t%s\n" (name n));
      Buffer.add_string data (sprintf "\t.align\t3\n%s:\n" (name n));
      let at =
        List.fold_left (fun at (off, w, v) ->
          if off > at then Buffer.add_string data (sprintf "\t.space\t%d\n" (off - at));
          (match v with
           | A.Imm x when w = 4 -> Buffer.add_string data (sprintf "\t.word\t%ld\n" (Int64.to_int32 x))
           | A.Imm x when w = 1 -> Buffer.add_string data (sprintf "\t.byte\t%Ld\n" (Int64.logand x 255L))
           | A.Addr { base = SB; name = Some m; off = o; _ } -> Buffer.add_string data (sprintf "\t.word\t%s+%Ld\n" (name m) o)
           | A.Str s -> String.iteri (fun i ch -> if i < w then Buffer.add_string data (sprintf "\t.byte\t%d\n" (Char.code ch))) s;
               if String.length s < w then Buffer.add_string data (sprintf "\t.space\t%d\n" (w - String.length s))
           | _ -> error "DATA %s: a value Gas doesn't know" n.sym);
          off + w) 0 ds
      in
      if size > at then Buffer.add_string data (sprintf "\t.space\t%d\n" (size - at))
    end) (List.rev !order);
  Buffer.contents out ^ Buffer.contents data
