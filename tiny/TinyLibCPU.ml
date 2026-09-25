(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny CPU of our own: its instruction set, an assembler, and an
 * interpreter; a CPU and its memory, no devices. The library of two
 * programs: TinyCPU.ml, the CPU run alone, its system calls answered
 * by the host; and TinyMachine.ml, the CPU with what a kernel needs
 * around it, its system calls traps. Knuth's road with MIX and MMIX:
 * when the machine is for teaching, design it; mini-5i (machine/) and
 * TinyCPUArm.ml emulate the machine history left us, this one the machine
 * fifty years of hindsight would draw.
 *
 * Why an assembler, in a file about a machine: the machine is new, so
 * nothing else writes its words. TinyCPUArm.ml could borrow GNU as (it
 * has its own assembler to check itself against as's bytes); this one
 * has no as to borrow, and a machine no one can program teaches
 * nothing. Programs by hand-encoded hex words would be the other way,
 * and MIX's lesson is that a machine for teaching comes with its
 * assembly language (MIXAL), the notation the book's programs are
 * written in. The assembler is kept small by the machine's design: one
 * format, every instruction 4 bytes, so two passes (the labels, then
 * the words) and no relaxation; its pseudo-instructions (li, la, call,
 * ret) are the only sequences it chooses.
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
 * sys                                                  imm: the call's number
 *
 * The immediate is signed but for andi, ori, xori (and lui); a shift
 * takes its amount modulo 32; a division by 0 gives -1 and leaves the
 * dividend as the remainder, and the one overflow (-2^31 / -1) gives
 * -2^31 and 0 (RISC-V's answers: an instruction set defines every
 * case). A system call takes its arguments in r1-r3 and answers in
 * r1 (what it does is the program's that runs the CPU). By
 * convention sp is r14 (the top of memory at the start), lr r15; the
 * assembler's pseudo-instructions: li, la (a value, an address: lui
 * and ori, or addi), mov, call, ret, j, nop.
 *
 * What makes it small:
 *
 * - {b The interpreter is the definition.} [step] is the machine's
 *   semantics, a match on the decoded word; memory holds the program,
 *   so a program may compute its code.
 * - {b A machine changes five things}, the fields of [env]: the fetch,
 *   a load, a store, a system call, and a word [decode] does not know.
 *   TinyCPU gives memory, the host's calls, and an error; a machine
 *   gives its pages, its devices behind addresses, a trap, and its own
 *   instructions (which
 *   the assembler and the listing learn by an [extension]). What
 *   happens between two instructions (an interrupt) is the loop's
 *   that calls [step], not [step]'s.
 * - {b The laws}: each program of TinyCPU_tests/ prints what is
 *   known otherwise (Python's answers); and a program's listing is
 *   assembly again, which reassembled gives the same words (print,
 *   parse, encode and decode agree; not for data, whose words may
 *   decode as instructions with bits the encoding ignores).
 *   TinyCPU_test.sh checks the first on its programs, the second
 *   on random programs of every instruction.
 *
 * Exercises, each cheap because the interpreter is the definition and
 * a machine changes the CPU only through env:
 * - a translator back (to arm32, as QEMU's): written once, 185 lines,
 *   then removed as a second topic (git history has it); the law, the
 *   same output interpreted and translated;
 * - a decode cache (threaded code): each word decoded once, into a
 *   closure kept by its address, and dropped when a store hits it;
 *   measure the speed against step;
 * - compressed instructions: 16-bit forms of the commonest (RISC-V's
 *   RVC), the density measured on tiny-os's programs, the listing's
 *   law checking them;
 * - a debugger by env: breakpoints as a word decode does not know,
 *   caught by illegal, the program's registers and memory then shown.
 *
 * References: D. E. Knuth, The Art of Computer Programming, vol. 1
 * (MIX, 1968; MMIX, fascicle 1, 2005): a machine designed to teach;
 * D. A. Patterson and J. L. Hennessy, the MIPS and RISC-V books: the
 * load-store machine; J. R. Bell, "Threaded Code" (CACM, 1973; from
 * memory); F. Bellard, "QEMU, a Fast and Portable Dynamic Translator"
 * (USENIX, 2005; from memory); A. Waterman, "Design of the RISC-V
 * Instruction Set Architecture" (PhD thesis, 2016; from memory), the
 * compressed instructions. *)

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

(* 2^20 bytes, TinyCPU's; a machine around the CPU may have more
 * (TinyMachine's 16 MB), set before its boot *)
let memsize = ref (1 lsl 20)
let sp = 14 and lr = 15

type machine = { r : int array; mutable pc : int; mem : Bytes.t }

(* what the program that runs the CPU decides *)
type env = {
  fetch : machine -> int -> int;           (* the instruction's word at pc *)
  load : machine -> size -> int -> int;
  store : machine -> size -> int -> int -> unit;
  sys : machine -> int -> unit;            (* the call's number, pc past the sys *)
  illegal : machine -> int -> unit;        (* the word, pc still on it *)
}

let addr a = a land (!memsize - 1)
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

(* memory alone, and an unknown word an error *)
let plain ~sys = {
  fetch = (fun m pc -> load m W pc);
  load; store; sys;
  illegal = (fun m w -> error "illegal instruction %08x at 0x%x" w m.pc);
}

(* one step: the word at pc fetched (from memory, or through the
 * machine's pages), decoded and run *)
let step env m =
  let pc = m.pc in
  let w = env.fetch m pc in
  match decode w with
  | None -> env.illegal m w
  | Some i ->
      let r = m.r in
      let set d v = if d <> 0 then r.(d) <- m32 v in
      m.pc <- addr (pc + 4);
      (match i with
       | Alu (op, d, a, b) -> set d (alu op r.(a) r.(b))
       | Alui (op, d, a, imm) -> set d (alu op r.(a) (m32 imm))
       | Lui (d, imm) -> set d (imm lsl 16)
       | Load (s, d, a, off) -> set d (env.load m s (r.(a) + off))
       | Store (s, d, a, off) -> env.store m s (r.(a) + off) r.(d)
       | Branch (c, d, a, off) -> if compare c r.(d) r.(a) then m.pc <- addr (pc + 4 + (4 * off))
       | Jal (d, off) -> set d (pc + 4); m.pc <- addr (pc + 4 + (4 * off))
       | Jalr (d, a, off) -> let t = word (r.(a) + off) in set d (pc + 4); m.pc <- t
       | Sys n -> env.sys m n)

(* the machine at its start: the image at 0, sp at the top of memory *)
let boot image =
  let m = { r = Array.make 16 0; pc = 0; mem = Bytes.make !memsize '\000' } in
  Bytes.blit_string image 0 m.mem 0 (String.length image);
  m.r.(sp) <- !memsize;
  m

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

(* what a machine adds to the language: its own instructions, a name
 * and the operands split to an item (None: not one of them), and
 * their words printed for the listing (None: not one of them) *)
type extension = { parse : string -> string list -> item option; show : int -> string option }
let no_extension = { parse = (fun _ _ -> None); show = (fun _ -> None) }

let instruction ?(ext = no_extension) name args : item =
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
  | _ ->
      (match ext.parse name args with
       | Some it -> it
       | None -> error "bad instruction: %s %s" name (String.concat ", " args))

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
let parse_line ?ext line : item list =
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
        List.rev acc @ [ (if name.[0] = '.' then directive name rest else instruction ?ext name rest) ] in
  go line []

(* the image, from address 0, of files assembled one after the other,
 * their labels one namespace: the link is no more than that *)
let assemble_files ?ext ?(origin = 0) (files : (string * string list) list) =
  let parse (name, lines) =
    (* each file on a word's boundary: one may end with bytes, the next begin with code *)
    Align 4 :: List.concat (List.mapi (fun n l -> try parse_line ?ext l with Error e -> error "%s:%d: %s" name (n + 1) e) lines) in
  let items = List.concat_map parse files in
  let labels = Hashtbl.create 64 in
  let pc = ref origin and placed = ref [] in
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
  if Buffer.length b > !memsize then error "the program does not fit in memory";
  Buffer.contents b

let assemble ?ext ?(name = "-") lines = assemble_files ?ext [ name, lines ]

(* files, named and read: .tm files assembled and linked, or one image
 * (the memory's first bytes, no header: the CPU starts at 0) *)
let image ?ext ?origin (files : (string * string) list) =
  match files with
  | _ :: _ when List.for_all (fun (f, _) -> Filename.check_suffix f ".tm") files ->
      assemble_files ?ext ?origin (List.map (fun (f, text) -> f, String.split_on_char '\n' text) files)
  | [ (f, text) ] -> if String.length text > !memsize then error "%s: larger than the memory" f; text
  | _ -> error "either .tm files or one image"

(* the listing: address, word, instruction, as assembly again *)
let listing ?(ext = no_extension) ?(origin = 0) image =
  List.init (String.length image / 4) (fun k ->
    let w = Int32.to_int (String.get_int32_le image (4 * k)) land 0xffffffff in
    Printf.sprintf "%x:\t%08x\t%s\n" (origin + (4 * k)) w
      (match decode w, ext.show w with
       | Some i, _ -> print ~pc:(origin + (4 * k)) i
       | None, Some s -> s
       | None, None -> Printf.sprintf ".word\t0x%x" w))
  |> String.concat ""

(* tiny-os v6's executables (plan_tiny_os.md): a.out's three words, a
 * magic, the image's size, its entry, then the image, assembled at
 * 0x800000, where v6 puts a process's program *)
let aout_origin = 0x800000
let aout_magic = 0x7a0ce5

let aout image =
  let b = Buffer.create (String.length image + 12) in
  List.iter (fun v -> Buffer.add_int32_le b (Int32.of_int v)) [ aout_magic; String.length image; aout_origin ];
  Buffer.add_string b image;
  Buffer.contents b
