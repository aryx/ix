(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny machine of our own, in one file: its instruction set, an
 * assembler, an interpreter, and a translator to arm32 that makes a
 * Linux executable of a program. Knuth's road with MIX and MMIX: when
 * the machine is for teaching, design it; mini-5i (machine/) and
 * TinyArm.ml emulate the machine history left us, this one the machine
 * fifty years of hindsight would draw:
 *
 *     tiny-machine prog.tm            assembled and interpreted
 *     tiny-machine -o prog prog.tm    translated to arm32: an ELF
 *     tiny-machine -l prog.tm         the listing
 *
 * The machine: 16 registers of 32 bits, r0 always 0 (a zero at hand
 * and a place to throw a result away, RISC-V's and MMIX's choice); a
 * byte-addressed memory of 2^20 bytes, the addresses taken modulo its
 * size (nothing faults), a word's two low address bits ignored (MMIX:
 * no alignment trap, and no alignment check either); no flags: a
 * branch compares two registers, slt makes a comparison a value (ARM's
 * flags are what an instruction set can do without). One format: an
 * 8-bit opcode, two 4-bit registers d and a, and a 16-bit immediate
 * whose low 4 bits name the third register of the three-register
 * instructions:
 *
 *     31      24 23  20 19  16 15                0
 *     |  opcode  |  d   |  a   |   immediate / b |
 *
 * add sub mul div rem and or xor shl shr sar slt sltu   d = a op b
 * addi andi ori xori shli shri sari slti sltiu        d = a op imm
 * lui                                                  d = imm << 16
 * ldw ldb stw stb                                      d, imm(a)
 * beq bne blt bge bltu bgeu                            d, a, label
 * jal jalr                                             d = pc + 4
 * sys                                                  imm: 0 exit, 1 write, 2 read
 *
 * The immediate is signed but for andi, ori, xori (and lui); a shift
 * takes its amount modulo 32; a division by 0 gives -1 and leaves the
 * dividend as the remainder, and the one overflow (-2^31 / -1) gives
 * -2^31 and 0 (RISC-V's answers: an instruction set defines every
 * case). A system call takes its arguments in r1-r3 and answers in
 * r1. By convention sp is r14 (the top of memory at the start), lr r15;
 * the assembler's pseudo-instructions: li, la (a value, an address: lui
 * and ori, or addi), mov, call, ret, j, nop.
 *
 * What makes it small, and still two machines:
 *
 * - {b The interpreter is the definition.} [step] is the machine's
 *   semantics, a match on the decoded word; memory holds the program,
 *   so a program may compute its code.
 * - {b The translator is a compiler from words to words.} Each
 *   instruction of the image becomes a fixed sequence of ARM
 *   instructions (known before any address: sizes first, then
 *   addresses, then the words, as TinyArm.ml's assembler); the guest's
 *   registers live in memory (QEMU's choice; a real translator would
 *   allocate host registers within a block), its memory is an array
 *   indexed by the address shifted left then right (the modulo); a
 *   branch becomes a branch to its target's translation; jalr looks
 *   its target up in a table of every word's translation; div and rem
 *   call a routine (machine/'s arm32 has no divide). What it cannot do,
 *   and the interpreter can, is run code the program writes: the
 *   translation is made once, before the run.
 * - {b The laws}: interpreting a program and running its translation
 *   (on the CPU, and under machine/'s mini-5i) print the same and exit
 *   the same; TinyMachine_test.sh checks them on the programs of
 *   TinyMachine_tests/, whose outputs are known otherwise, and on
 *   random programs that dump every register.
 *
 * Usage: tiny-machine [-o out | -l] file.tm [args...]
 *
 * References: D. E. Knuth, The Art of Computer Programming, vol. 1
 * (MIX, 1968; MMIX, fascicle 1, 2005): a machine designed to teach;
 * D. A. Patterson and J. L. Hennessy, the MIPS and RISC-V books: the
 * load-store machine; F. Bellard, QEMU (2005): the translator's shape. *)

(*****************************************************************************)
(* The instructions *)
(*****************************************************************************)

type reg = int

type alu = Add | Sub | Mul | Div | Rem | And | Or | Xor | Shl | Shr | Sar | Slt | Sltu
type cmp = Eq | Ne | Lt | Ge | Ltu | Geu
type size = W | B

type instr =
  | Alu of alu * reg * reg * reg          (* d, a, b *)
  | Alui of alu * reg * reg * int         (* d, a, imm: add and or xor shl shr sar slt sltu *)
  | Lui of reg * int
  | Load of size * reg * reg * int        (* d, a, offset *)
  | Store of size * reg * reg * int       (* the value's register, a, offset *)
  | Branch of cmp * reg * reg * int       (* d, a, offset in words, from pc + 4 *)
  | Jal of reg * int
  | Jalr of reg * reg * int
  | Sys of int

let alus = [| Add; Sub; Mul; Div; Rem; And; Or; Xor; Shl; Shr; Sar; Slt; Sltu |]
let alu_names = [| "add"; "sub"; "mul"; "div"; "rem"; "and"; "or"; "xor"; "shl"; "shr"; "sar"; "slt"; "sltu" |]
let cmps = [| Eq; Ne; Lt; Ge; Ltu; Geu |]
let cmp_names = [| "beq"; "bne"; "blt"; "bge"; "bltu"; "bgeu" |]
let index a x = let rec go i = if a.(i) = x then i else go (i + 1) in go 0

(* an immediate form's name: the operation's and an i, but sltiu (MIPS's) *)
let imm_name op = match op with Sltu -> "sltiu" | _ -> alu_names.(index alus op) ^ "i"

(* the immediate forms: those whose immediate is zero-extended *)
let unsigned_imm = function And | Or | Xor -> true | _ -> false
let has_imm = function Mul | Div | Rem | Sub -> false | _ -> true

let m32 v = v land 0xffffffff
let sext16 v = ((v land 0xffff) lxor 0x8000) - 0x8000
let signed v = ((v land 0xffffffff) lxor 0x80000000) - 0x80000000

exception Error of string
let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

(* opcodes: 0x01-0x0d the ALU, 0x11-0x1d its immediate forms, then the
 * rest; 0 is no instruction, so that zeroed memory stops a program *)
let encode i =
  let w op d a imm = (op lsl 24) lor (d lsl 20) lor (a lsl 16) lor (imm land 0xffff) in
  let fits16 v = v >= -0x8000 && v < 0x8000 in
  match i with
  | Alu (op, d, a, b) -> w (1 + index alus op) d a b
  | Alui (op, d, a, imm) ->
      if not (if unsigned_imm op then imm >= 0 && imm < 0x10000 else fits16 imm) then error "immediate %d out of range" imm;
      w (0x11 + index alus op) d a imm
  | Lui (d, imm) -> w 0x20 d 0 imm
  | Load (s, d, a, off) -> if not (fits16 off) then error "offset %d out of range" off; w (if s = W then 0x21 else 0x22) d a off
  | Store (s, d, a, off) -> if not (fits16 off) then error "offset %d out of range" off; w (if s = W then 0x23 else 0x24) d a off
  | Branch (c, d, a, off) -> if not (fits16 off) then error "branch too far"; w (0x30 + index cmps c) d a off
  | Jal (d, off) -> if not (fits16 off) then error "jump too far"; w 0x38 d 0 off
  | Jalr (d, a, off) -> w 0x39 d a off
  | Sys n -> w 0x3f 0 0 n

let decode w =
  let op = (w lsr 24) land 0xff and d = (w lsr 20) land 15 and a = (w lsr 16) land 15 and imm = w land 0xffff in
  match op with
  | _ when op >= 0x01 && op <= 0x0d -> Some (Alu (alus.(op - 1), d, a, imm land 15))
  | _ when op >= 0x11 && op <= 0x1d && has_imm alus.(op - 0x11) ->
      let alu = alus.(op - 0x11) in
      Some (Alui (alu, d, a, if unsigned_imm alu then imm else sext16 imm))
  | 0x20 -> Some (Lui (d, imm))
  | 0x21 -> Some (Load (W, d, a, sext16 imm)) | 0x22 -> Some (Load (B, d, a, sext16 imm))
  | 0x23 -> Some (Store (W, d, a, sext16 imm)) | 0x24 -> Some (Store (B, d, a, sext16 imm))
  | _ when op >= 0x30 && op <= 0x35 -> Some (Branch (cmps.(op - 0x30), d, a, sext16 imm))
  | 0x38 -> Some (Jal (d, sext16 imm))
  | 0x39 -> Some (Jalr (d, a, sext16 imm))
  | 0x3f -> Some (Sys imm)
  | _ -> None

let print ~pc i =
  let r k = "r" ^ string_of_int k in
  let target off = Printf.sprintf "0x%x" (pc + 4 + (4 * off)) in
  match i with
  | Alu (op, d, a, b) -> Printf.sprintf "%s\t%s, %s, %s" alu_names.(index alus op) (r d) (r a) (r b)
  | Alui (op, d, a, imm) -> Printf.sprintf "%s\t%s, %s, %d" (imm_name op) (r d) (r a) imm
  | Lui (d, imm) -> Printf.sprintf "lui\t%s, 0x%x" (r d) imm
  | Load (s, d, a, off) -> Printf.sprintf "%s\t%s, %d(%s)" (if s = W then "ldw" else "ldb") (r d) off (r a)
  | Store (s, d, a, off) -> Printf.sprintf "%s\t%s, %d(%s)" (if s = W then "stw" else "stb") (r d) off (r a)
  | Branch (c, d, a, off) -> Printf.sprintf "%s\t%s, %s, %s" cmp_names.(index cmps c) (r d) (r a) (target off)
  | Jal (d, off) -> Printf.sprintf "jal\t%s, %s" (r d) (target off)
  | Jalr (d, a, off) -> Printf.sprintf "jalr\t%s, %d(%s)" (r d) off (r a)
  | Sys n -> Printf.sprintf "sys\t%d" n

(*****************************************************************************)
(* The machine: the interpreter *)
(*****************************************************************************)

let memsize = 1 lsl 20
let sp = 14 and lr = 15

type machine = { r : int array; mutable pc : int; mem : Bytes.t }

exception Exit of int

let addr a = a land (memsize - 1)
let word a = addr a land lnot 3
let load m = function W -> fun a -> Int32.to_int (Bytes.get_int32_le m.mem (word a)) land 0xffffffff | B -> fun a -> Char.code (Bytes.get m.mem (addr a))
let store m s a v = match s with
  | W -> Bytes.set_int32_le m.mem (word a) (Int32.of_int (m32 v))
  | B -> Bytes.set m.mem (addr a) (Char.chr (v land 0xff))

let alu op a b =
  let sa = signed a and sb = signed b in
  m32 (match op with
    | Add -> a + b | Sub -> a - b | Mul -> a * b
    | Div -> if b = 0 then -1 else if sa = -0x80000000 && sb = -1 then sa else Int.div sa sb   (* truncated *)
    | Rem -> if b = 0 then a else if sa = -0x80000000 && sb = -1 then 0 else Int.rem sa sb
    | And -> a land b | Or -> a lor b | Xor -> a lxor b
    | Shl -> a lsl (b land 31) | Shr -> a lsr (b land 31) | Sar -> sa asr (b land 31)
    | Slt -> if sa < sb then 1 else 0 | Sltu -> if a < b then 1 else 0)

let compare c a b =
  match c with
  | Eq -> a = b | Ne -> a <> b | Lt -> signed a < signed b | Ge -> signed a >= signed b | Ltu -> a < b | Geu -> a >= b

type caps = < Cap.stdin; Cap.stdout; Cap.stderr >

let syscall (caps : < caps; .. >) m n =
  let r = m.r in
  match n with
  | 0 -> raise (Exit (r.(1) land 0xff))
  | 1 ->
      let s = String.init r.(3) (fun i -> Bytes.get m.mem (addr (r.(2) + i))) in
      if r.(1) = 2 then Console.eprint caps s else (Console.print caps s; flush stdout);
      r.(1) <- r.(3)
  | 2 ->
      let (_ : < Cap.stdin; .. >) = caps in
      let b = Bytes.create r.(3) in
      let k = try input stdin b 0 r.(3) with Sys_error _ -> 0 in
      Bytes.iteri (fun i c -> if i < k then Bytes.set m.mem (addr (r.(2) + i)) c) b;
      r.(1) <- k
  | n -> error "unknown system call %d" n

let step caps m =
  let pc = m.pc in
  let w = load m W pc in
  let i = match decode w with Some i -> i | None -> error "illegal instruction %08x at 0x%x" w pc in
  let r = m.r in
  let set d v = if d <> 0 then r.(d) <- m32 v in
  m.pc <- addr (pc + 4);
  (match i with
   | Alu (op, d, a, b) -> set d (alu op r.(a) r.(b))
   | Alui (op, d, a, imm) -> set d (alu op r.(a) (m32 imm))
   | Lui (d, imm) -> set d (imm lsl 16)
   | Load (s, d, a, off) -> set d (load m s (r.(a) + off))
   | Store (s, d, a, off) -> store m s (r.(a) + off) r.(d)
   | Branch (c, d, a, off) -> if compare c r.(d) r.(a) then m.pc <- addr (pc + 4 + (4 * off))
   | Jal (d, off) -> set d (pc + 4); m.pc <- addr (pc + 4 + (4 * off))
   | Jalr (d, a, off) -> let t = word (r.(a) + off) in set d (pc + 4); m.pc <- t
   | Sys n -> syscall caps m n)

let interpret caps image =
  let m = { r = Array.make 16 0; pc = 0; mem = Bytes.make memsize '\000' } in
  Bytes.blit_string image 0 m.mem 0 (String.length image);
  m.r.(sp) <- memsize;
  try while true do step caps m done; 0 with Exit n -> n

(*****************************************************************************)
(* The assembler *)
(*****************************************************************************)

type expr = Num of int | Sym of string

(* an item of the program: its size in bytes known when it is parsed,
 * its bytes made once the labels are *)
type item = Label of string | Words of int * (int -> (expr -> int) -> int list) | Bytes_ of string | Align of int

let trim = String.trim

let reg s =
  match trim s with
  | "zero" -> 0 | "sp" -> sp | "lr" -> lr
  | s when String.length s >= 2 && s.[0] = 'r' ->
      (match int_of_string_opt (String.sub s 1 (String.length s - 1)) with Some n when n >= 0 && n < 16 -> n | _ -> error "not a register: %s" s)
  | s -> error "not a register: %s" s

let expr s =
  let s = trim s in
  if String.length s = 3 && s.[0] = '\'' && s.[2] = '\'' then Num (Char.code s.[1])
  else match int_of_string_opt s with Some n -> Num n | None -> Sym s

(* "off(ra)" or "(ra)" *)
let mem_operand s =
  let s = trim s in
  match String.index_opt s '(' with
  | Some i when s.[String.length s - 1] = ')' ->
      let off = trim (String.sub s 0 i) in
      reg (String.sub s (i + 1) (String.length s - i - 2)), (if off = "" then Num 0 else expr off)
  | _ -> error "not a memory operand: %s" s

let one f = Words (4, fun pc res -> [ encode (f pc res) ])

(* a branch's offset, in words from the next instruction *)
let offset pc res e = let t = res e in if t land 3 <> 0 then error "unaligned target 0x%x" t; (t - (pc + 4)) / 4

let instruction name args : item =
  let args = List.map trim (if trim args = "" then [] else String.split_on_char ',' args) in
  let alu_of n = match index alu_names n with i -> Some alus.(i) | exception _ -> None in
  let imm_op n = Array.find_opt (fun op -> has_imm op && imm_name op = n) alus in
  match name, args with
  | _, [ d; a; b ] when alu_of name <> None -> one (fun _ _ -> Alu (Option.get (alu_of name), reg d, reg a, reg b))
  | _, [ d; a; v ] when imm_op name <> None && has_imm (Option.get (imm_op name)) ->
      one (fun _ res -> Alui (Option.get (imm_op name), reg d, reg a, res (expr v)))
  | "lui", [ d; v ] -> one (fun _ res -> Lui (reg d, res (expr v) land 0xffff))
  | ("ldw" | "ldb" | "stw" | "stb"), [ d; m ] ->
      one (fun _ res ->
        let a, off = mem_operand m in
        let s = if name.[2] = 'w' then W else B in
        if name.[0] = 'l' then Load (s, reg d, a, res off) else Store (s, reg d, a, res off))
  | _, [ d; a; t ] when Array.mem name cmp_names ->
      one (fun pc res -> Branch (cmps.(index cmp_names name), reg d, reg a, offset pc res (expr t)))
  | "jal", [ d; t ] -> one (fun pc res -> Jal (reg d, offset pc res (expr t)))
  | "jalr", [ d; m ] -> one (fun _ res -> let a, off = mem_operand m in Jalr (reg d, a, res off))
  | "sys", [ n ] -> one (fun _ res -> Sys (res (expr n)))
  (* the pseudo-instructions *)
  | "li", [ d; v ] when (match expr v with Num n -> n >= -0x8000 && n < 0x8000 | Sym _ -> false) ->
      one (fun _ res -> Alui (Add, reg d, 0, res (expr v)))
  | ("li" | "la"), [ d; v ] ->
      Words (8, fun _ res ->
        let x = m32 (res (expr v)) in
        [ encode (Lui (reg d, x lsr 16)); encode (Alui (Or, reg d, reg d, x land 0xffff)) ])
  | "mov", [ d; a ] -> one (fun _ _ -> Alui (Add, reg d, reg a, 0))
  | "call", [ t ] -> one (fun pc res -> Jal (lr, offset pc res (expr t)))
  | "j", [ t ] -> one (fun pc res -> Jal (0, offset pc res (expr t)))
  | "ret", [] -> one (fun _ _ -> Jalr (0, lr, 0))
  | "nop", [] -> one (fun _ _ -> Alui (Add, 0, 0, 0))
  | _ -> error "bad instruction: %s %s" name (String.concat ", " args)

(* a string's escapes: backslash and n, t or 0, or the character *)
let unescape s =
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i < String.length s then
      if s.[i] = '\\' && i + 1 < String.length s then
        (Buffer.add_char b (match s.[i + 1] with 'n' -> '\n' | 't' -> '\t' | '0' -> '\000' | c -> c); go (i + 2))
      else (Buffer.add_char b s.[i]; go (i + 1)) in
  go 0; Buffer.contents b

let directive d args : item =
  match d with
  | ".word" ->
      let es = List.map expr (String.split_on_char ',' args) in
      Words (4 * List.length es, fun _ res -> List.map (fun e -> m32 (res e)) es)
  | ".byte" -> Bytes_ (String.concat "" (List.map (fun e -> match expr e with Num n -> String.make 1 (Char.chr (n land 0xff)) | Sym _ -> error ".byte takes numbers") (String.split_on_char ',' args)))
  | ".ascii" | ".asciz" ->
      let a = trim args in
      if String.length a < 2 || a.[0] <> '"' || a.[String.length a - 1] <> '"' then error "not a string: %s" a;
      Bytes_ (unescape (String.sub a 1 (String.length a - 2)) ^ if d = ".asciz" then "\000" else "")
  | ".space" -> Bytes_ (String.make (int_of_string (trim args)) '\000')
  | ".align" -> Align (int_of_string (trim args))
  | _ -> error "unknown directive %s" d

(* a line: labels, then an instruction or a directive; ; starts a comment *)
let parse_line line : item list =
  let line = match String.index_opt line ';' with
    | Some i when not (String.contains (String.sub line 0 i) '"') -> String.sub line 0 i
    | _ -> line in
  let rec go s acc =
    let s = trim s in
    match String.index_opt s ':' with
    | Some i when not (String.contains (String.sub s 0 i) ' ') && not (String.contains (String.sub s 0 i) '"') ->
        go (String.sub s (i + 1) (String.length s - i - 1)) (Label (String.sub s 0 i) :: acc)
    | _ when s = "" -> List.rev acc
    | _ ->
        let i = try String.index_from s 0 ' ' with Not_found -> String.length s in
        let i = min i (try String.index s '\t' with Not_found -> String.length s) in
        let name = String.sub s 0 i and rest = String.sub s i (String.length s - i) in
        List.rev acc @ [ (if name.[0] = '.' then directive name rest else instruction name rest) ] in
  go line []

(* the image, from address 0, its labels, and its instructions' addresses *)
let assemble lines =
  let items = List.concat (List.mapi (fun n l -> try parse_line l with Error e -> error "line %d: %s" (n + 1) e) lines) in
  let labels = Hashtbl.create 64 in
  let pc = ref 0 and placed = ref [] in
  List.iter (fun it ->
    match it with
    | Label l -> if Hashtbl.mem labels l then error "label %s defined twice" l; Hashtbl.replace labels l !pc
    | Align n -> let a = (!pc + n - 1) / n * n in placed := (!pc, Bytes_ (String.make (a - !pc) '\000')) :: !placed; pc := a
    | Words (n, _) -> placed := (!pc, it) :: !placed; pc := !pc + n
    | Bytes_ s -> placed := (!pc, it) :: !placed; pc := !pc + String.length s) items;
  let resolve = function Num n -> n | Sym s -> (match Hashtbl.find_opt labels s with Some a -> a | None -> error "undefined label %s" s) in
  let b = Buffer.create 4096 in
  List.iter (fun (a, it) ->
    match it with
    | Words (_, f) -> List.iter (fun w -> Buffer.add_int32_le b (Int32.of_int w)) (f a resolve)
    | Bytes_ s -> Buffer.add_string b s
    | Label _ | Align _ -> ()) (List.rev !placed);
  if Buffer.length b > memsize then error "the program does not fit in memory";
  Buffer.contents b

(*****************************************************************************)
(* The translator, to arm32 *)
(*****************************************************************************)

(* the few ARM instructions the translation needs, as words (arm32's
 * encodings; TinyArm.ml has the whole of them) *)
module A = struct
  let al = 0xe and eq = 0 and ne = 1 and hs = 2 and lo = 3 and ge = 10 and lt = 11
  let and_ = 0 and eor = 1 and sub = 2 and rsb = 3 and add = 4 and adc = 5 and cmp = 10 and orr = 12 and mov = 13
  and bic = 14 and mvn = 15
  (* data processing: the second operand an 8-bit immediate, or a
   * register shifted (sh: 0 lsl, 1 lsr, 2 asr) by n or by a register *)
  let dp ?(c = al) ?(s = false) op rd rn o2 =
    (c lsl 28) lor (op lsl 21) lor ((if s || op = cmp then 1 else 0) lsl 20) lor (rn lsl 16) lor (rd lsl 12) lor o2
  let imm v = assert (v >= 0 && v < 256); (1 lsl 25) lor v
  let reg ?(sh = 0) ?(n = 0) rm = (n lsl 7) lor (sh lsl 5) lor rm
  let by sh rs rm = (rs lsl 8) lor (sh lsl 5) lor 0x10 lor rm
  (* ldr and str: [rn, #off], or [rn, rm, lsr #n] *)
  let ldr ?(byte = false) rd rn off = (al lsl 28) lor (0x59 lsl 20) lor ((if byte then 1 else 0) lsl 22) lor (rn lsl 16) lor (rd lsl 12) lor off
  let str ?byte rd rn off = ldr ?byte rd rn off land lnot (1 lsl 20)
  let ldr_r ?(byte = false) rd rn rm n =
    (al lsl 28) lor (0x79 lsl 20) lor ((if byte then 1 else 0) lsl 22) lor (rn lsl 16) lor (rd lsl 12) lor (n lsl 7) lor (1 lsl 5) lor rm
  let str_r ?byte rd rn rm n = ldr_r ?byte rd rn rm n land lnot (1 lsl 20)
  let mul rd rm rs = (al lsl 28) lor (rd lsl 16) lor (rs lsl 8) lor 0x90 lor rm
  (* a branch [words] instructions away (from the branch itself) *)
  let b ?(c = al) ?(link = false) words = (c lsl 28) lor (5 lsl 25) lor ((if link then 1 else 0) lsl 24) lor ((words - 2) land 0xffffff)
  let svc = 0xef000000
  let bxeq_lr = 0x012fff1e
end

(* the translation's registers: r11 the guest's registers, r10 its
 * memory, r9 the jump table; r0-r3 scratch *)
let regs = 11 and mem = 10 and table = 9

(* a word of the translation, or a branch to an address known later *)
type target = Guest of int | Div | Trap
type piece = W of int | Jump of int * bool * target       (* its condition, link *)

let get rx k = if k = 0 then [ W (A.dp A.mov rx 0 (A.imm 0)) ] else [ W (A.ldr rx regs (4 * k)) ]
let put rx k = if k = 0 then [] else [ W (A.str rx regs (4 * k)) ]

(* a constant into rx: a mov for a byte, else a word loaded from right
 * after a branch over it (the pc reads 8 ahead: offset 0) *)
let const rx v =
  let v = m32 v in
  if v < 256 then [ W (A.dp A.mov rx 0 (A.imm v)) ] else [ W (A.ldr rx 15 0); W (A.b 2); W v ]

(* r0, an address, modulo the memory's size: shifted left by 12 here,
 * back right by 12 in the access *)
let wrap ~word = (if word then [ W (A.dp A.bic 0 0 (A.imm 3)) ] else []) @ [ W (A.dp A.mov 0 0 (A.reg ~n:12 0)) ]

let alu_body op =
  match op with
  | Add -> [ W (A.dp A.add 0 0 (A.reg 1)) ]
  | Sub -> [ W (A.dp A.sub 0 0 (A.reg 1)) ]
  | Mul -> [ W (A.mul 2 0 1); W (A.dp A.mov 0 0 (A.reg 2)) ]
  | Div -> [ Jump (A.al, true, Div) ]
  | Rem -> [ Jump (A.al, true, Div); W (A.dp A.mov 0 0 (A.reg 1)) ]
  | And -> [ W (A.dp A.and_ 0 0 (A.reg 1)) ]
  | Or -> [ W (A.dp A.orr 0 0 (A.reg 1)) ]
  | Xor -> [ W (A.dp A.eor 0 0 (A.reg 1)) ]
  | Shl | Shr | Sar ->
      let sh = match op with Shl -> 0 | Shr -> 1 | _ -> 2 in
      [ W (A.dp A.and_ 1 1 (A.imm 31)); W (A.dp A.mov 0 0 (A.by sh 1 0)) ]
  | Slt | Sltu ->
      let yes, no = if op = Slt then A.lt, A.ge else A.lo, A.hs in
      [ W (A.dp A.cmp 0 0 (A.reg 1)); W (A.dp ~c:yes A.mov 0 0 (A.imm 1)); W (A.dp ~c:no A.mov 0 0 (A.imm 0)) ]

(* one guest word at [pc], its translation *)
let translate_one ~image_size pc (i : instr option) : piece list =
  let guest t = let t = addr t in if t < image_size then Guest t else Trap in
  match i with
  (* no instruction, or no such system call: what the interpreter
   * stops on *)
  | None -> [ Jump (A.al, false, Trap) ]
  | Some (Sys n) when n > 2 -> [ Jump (A.al, false, Trap) ]
  | Some i ->
      match i with
      | Alu (op, d, a, b) -> get 0 a @ get 1 b @ alu_body op @ put 0 d
      | Alui (op, d, a, imm) -> get 0 a @ const 1 imm @ alu_body op @ put 0 d
      | Lui (d, imm) -> const 0 (imm lsl 16) @ put 0 d
      | Load (s, d, a, off) ->
          get 0 a @ const 1 off @ [ W (A.dp A.add 0 0 (A.reg 1)) ] @ wrap ~word:(s = W)
          @ [ W (A.ldr_r ~byte:(s = B) 0 mem 0 12) ] @ put 0 d
      | Store (s, d, a, off) ->
          get 0 a @ const 1 off @ [ W (A.dp A.add 0 0 (A.reg 1)) ] @ wrap ~word:(s = W) @ get 2 d
          @ [ W (A.str_r ~byte:(s = B) 2 mem 0 12) ]
      | Branch (c, d, a, off) ->
          let cond = match c with Eq -> A.eq | Ne -> A.ne | Lt -> A.lt | Ge -> A.ge | Ltu -> A.lo | Geu -> A.hs in
          get 0 d @ get 1 a @ [ W (A.dp A.cmp 0 0 (A.reg 1)); Jump (cond, false, guest (pc + 4 + (4 * off))) ]
      | Jal (d, off) -> const 0 (pc + 4) @ put 0 d @ [ Jump (A.al, false, guest (pc + 4 + (4 * off))) ]
      | Jalr (d, a, off) ->
          (* the target first (d may be a), a word modulo the memory;
           * its translation from the table, when inside the image *)
          get 0 a @ const 1 off
          @ [ W (A.dp A.add 3 0 (A.reg 1)); W (A.dp A.bic 3 3 (A.imm 3)); W (A.dp A.mov 3 0 (A.reg ~n:12 3));
              W (A.dp A.mov 3 0 (A.reg ~sh:1 ~n:12 3)) ]
          @ const 1 image_size @ [ W (A.dp A.cmp 0 3 (A.reg 1)); Jump (A.hs, false, Trap) ]
          @ const 0 (pc + 4) @ put 0 d @ [ W (A.ldr_r 15 table 3 0 land lnot (1 lsl 5)) ]
      | Sys 0 -> get 0 1 @ [ W (A.dp A.mov 7 0 (A.imm 1)); W A.svc ]
      | Sys n ->
          (* r1: the host's address of the guest's, modulo the memory *)
          get 0 2 @ [ W (A.dp A.mov 0 0 (A.reg ~n:12 0)); W (A.dp A.mov 0 0 (A.reg ~sh:1 ~n:12 0)); W (A.dp A.add 1 mem (A.reg 0)) ]
          @ get 0 1 @ get 2 3 @ [ W (A.dp A.mov 7 0 (A.imm (if n = 1 then 4 else 3))); W A.svc ] @ put 0 1

(* division, RISC-V's answers, by shift and subtract: r0 / r1 into r0,
 * the remainder into r1 *)
let div_routine = List.map (fun w -> W w) [
  A.dp A.cmp 0 1 (A.imm 0);
  A.dp ~c:A.eq A.mov 1 0 (A.reg 0);                  (* by 0: the dividend, and -1 *)
  A.dp ~c:A.eq A.mvn 0 0 (A.imm 0);
  A.bxeq_lr;
  0xe92d4070;                                         (* push {r4, r5, r6, lr} *)
  A.dp A.eor 6 0 (A.reg 1);                           (* the quotient's sign, bit 31 *)
  A.dp A.mov 5 0 (A.reg 0);                           (* the remainder's, the dividend's *)
  A.dp A.cmp 0 0 (A.imm 0); A.dp ~c:A.lt A.rsb 0 0 (A.imm 0);
  A.dp A.cmp 0 1 (A.imm 0); A.dp ~c:A.lt A.rsb 1 1 (A.imm 0);
  A.dp A.mov 2 0 (A.imm 0); A.dp A.mov 3 0 (A.imm 0); A.dp A.mov 4 0 (A.imm 32);
  (* each bit of the dividend, from the top, into the remainder *)
  A.dp ~s:true A.mov 0 0 (A.reg ~n:1 0);
  A.dp A.adc 3 3 (A.reg 3);
  A.dp A.mov 2 0 (A.reg ~n:1 2);
  A.dp A.cmp 0 3 (A.reg 1);
  A.dp ~c:A.hs A.sub 3 3 (A.reg 1);
  A.dp ~c:A.hs A.orr 2 2 (A.imm 1);
  A.dp ~s:true A.sub 4 4 (A.imm 1);
  A.b ~c:A.ne (-7);
  A.dp A.cmp 0 6 (A.imm 0); A.dp ~c:A.lt A.rsb 2 2 (A.imm 0);
  A.dp A.cmp 0 5 (A.imm 0); A.dp ~c:A.lt A.rsb 3 3 (A.imm 0);
  A.dp A.mov 0 0 (A.reg 2); A.dp A.mov 1 0 (A.reg 3);
  0xe8bd8070 ]                                        (* pop {r4, r5, r6, pc} *)

(* what the interpreter does with an illegal instruction: exit 1 *)
let trap_routine = List.map (fun w -> W w) [ A.dp A.mov 0 0 (A.imm 1); A.dp A.mov 7 0 (A.imm 1); A.svc ]

(* the executable: the ELF headers, then at 0x10054 the entry, a
 * translation per word of the image, the routines, the jump table, the
 * guest's registers and its memory (the image, then zeros: the
 * segment's size beyond the file's) *)
let base = 0x10000
let origin = base + 52 + 32

let translate image =
  let n = (String.length image + 3) / 4 in
  let image_size = 4 * n in
  let word k = if 4 * k + 4 <= String.length image then Int32.to_int (String.get_int32_le image (4 * k)) land 0xffffffff else 0 in
  let guests = List.init n (fun k -> translate_one ~image_size (4 * k) (decode (word k))) in
  (* the addresses: the entry's size is fixed: 3 constants, sp set, a jump *)
  let entry_size = 4 * ((3 * 3) + 4 + 1) in
  let starts = Array.make n 0 in
  let pos = ref (origin + entry_size) in
  List.iteri (fun k g -> starts.(k) <- !pos; pos := !pos + (4 * List.length g)) guests;
  let div_at = !pos in
  let trap_at = div_at + (4 * List.length div_routine) in
  let table_at = trap_at + (4 * List.length trap_routine) in
  let regs_at = table_at + image_size in
  let mem_at = regs_at + 64 in
  let entry = const regs regs_at @ const mem mem_at @ const table table_at
              @ [ W (A.ldr 0 15 0); W (A.b 2); W memsize; W (A.str 0 regs (4 * sp)) ]
              @ [ Jump (A.al, false, if n > 0 then Guest 0 else Trap) ] in
  assert (4 * List.length entry = entry_size);
  let b = Buffer.create (mem_at - origin + image_size) in
  let emit pieces =
    List.iter (fun p ->
      let here = origin + Buffer.length b in
      let w = match p with
        | W w -> w
        | Jump (c, link, t) ->
            let dest = match t with Guest a -> starts.(a / 4) | Div -> div_at | Trap -> trap_at in
            A.b ~c ~link ((dest - here) / 4) in
      Buffer.add_int32_le b (Int32.of_int w)) pieces in
  emit entry;
  List.iter emit guests;
  emit div_routine;
  emit trap_routine;
  Array.iter (fun a -> Buffer.add_int32_le b (Int32.of_int a)) starts;
  Buffer.add_string b (String.make 64 '\000');
  Buffer.add_string b image;
  let file = 52 + 32 + Buffer.length b in
  let h = Buffer.create 84 in
  let u16 v = Buffer.add_uint16_le h v and u32 v = Buffer.add_int32_le h (Int32.of_int v) in
  Buffer.add_string h "\x7fELF\001\001\001\000"; Buffer.add_string h (String.make 8 '\000');
  u16 2; u16 40; u32 1; u32 origin; u32 52; u32 0; u32 0x05000000; u16 52; u16 32; u16 1; u16 0; u16 0; u16 0;
  u32 1; u32 0; u32 base; u32 base; u32 file; u32 (mem_at - base + memsize); u32 7; u32 0x1000;
  Buffer.contents h ^ Buffer.contents b

(*****************************************************************************)
(* Main *)
(*****************************************************************************)

let main (caps : < caps; Cap.argv; Cap.open_in; Cap.open_out; .. >) =
  let args = List.tl (Array.to_list (CapSys.argv caps)) in
  let read f = Files.read caps (Fpath.v f) |> String.split_on_char '\n' in
  try
    match args with
    | "-l" :: file :: _ ->
        let image = assemble (read file) in
        for k = 0 to (String.length image / 4) - 1 do
          let w = Int32.to_int (String.get_int32_le image (4 * k)) land 0xffffffff in
          Console.print caps (Printf.sprintf "%x:\t%08x\t%s\n" (4 * k) w
                                (match decode w with Some i -> print ~pc:(4 * k) i | None -> ".word"))
        done; 0
    | "-o" :: out :: file :: _ -> Files.write caps ~perm:0o755 (Fpath.v out) (translate (assemble (read file))); 0
    | file :: _ when file.[0] <> '-' -> interpret caps (assemble (read file))
    | _ -> Console.eprint caps "usage: tiny-machine [-o out | -l] file.tm [args...]\n"; 2
  with Error e | Sys_error e -> Console.eprint caps ("tiny-machine: " ^ e ^ "\n"); 1

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
