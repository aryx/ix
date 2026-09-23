(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny assembler for arm64 that writes the executable, in one file.
 * TinyAsm and TinyLd (assembler/, linker/) are Plan 9's split,
 * faithfully: an assembler that only parses into objects, and a linker
 * that loads them and their libraries, lays out and encodes, choosing
 * for each instruction the form 7l would, byte for byte. This is what
 * is left without separate compilation:
 *
 *     tinyassembler -o hello hello.s libc/*.s && ./hello
 *
 * all the assembly of a program, its own and its libc's (7c -S output,
 * and libc's .s), read at once, and the ELF executable written.
 *
 * What makes it small, and still a real toolchain:
 *
 * - {b Every size is known before any address.} An instruction's
 *   expansion depends on its operands only, never on where things end
 *   up: a constant is built by MOVZ, MOVK or MOVN (up to four), an
 *   address by ADRP and ADD, pc-relative (a global's load by ADRP, ADD
 *   and the load), a logical immediate in a register. So there is no
 *   literal pool, no bitmask encoder, no relaxation, and no second
 *   guess: expand, then lay out, then encode, one pass each. The
 *   executable is about 7l's size: where 7l loads from a pool, this
 *   builds, and it has no pool words (hello with libc: 27,328 bytes,
 *   against 7l's 27,606).
 * - {b The encoding is a word per closure}: each instruction becomes a
 *   list of functions from their own pc to 32 bits, run once every
 *   address is known. That is Plan 9's point (encode in the linker,
 *   when addresses are known) with the linker and the assembler made
 *   one: the objects in between are gone.
 * - {b A library is its reachable functions.} What an archive's index
 *   does (take the objects that define what is undefined), a walk from
 *   the entry does at the granularity of functions and data: the
 *   executable has what the program uses, and a name defined twice is
 *   its first definition (fmt's strtod before port's, as ar has it).
 *   A name<> is its file's.
 * - {b 7l's frames}, because 7c's code counts on them: the frame
 *   16-aligned with R30 at its bottom, pushed by a pre-indexed store; a
 *   leaf without locals makes none; RETURN undoes it. n+8(FP) is the
 *   caller's frame, x-8(SP) this one's.
 * - {b The file is ELF with one segment}: the header, the text and the
 *   data in one read-write-execute PT_LOAD, then the bss; no sections.
 *
 * The instructions are what 7c emits and libc's .s use: MOV and its
 * widths (MOVW MOVWU MOVH MOVHU MOVB MOVBU) between registers,
 * constants, addresses and memory (o(R), o(SP), o(FP), sym(SB)); ADD
 * SUB AND ORR EOR BIC CMP CMN and their W and S forms; NEG MVN LSL LSR
 * ASR MUL UMULL SMULL SDIV UDIV REM UREM, SXTW and the extensions; B BL
 * (to a name, a label, n(PC) or a register), the conditional branches,
 * CBZ CBNZ, RETURN RET SVC, CASE and BCASE; floating point: FMOVD
 * FMOVS, FADD FSUB FMUL FDIV FCMP (D and S), the conversions. TEXT
 * DATA GLOBL, labels, // and /* comments.
 *
 * Left out, against TinyLd: arm (5, and its conditional execution,
 * pools and division calls); Mach-O (its code would be the same, being
 * pc-relative; the rebase of the data's pointers is the missing part:
 * an exercise) and a.out; libraries and objects, which is the point;
 * 7l's follow (dead code after a RET stays); the byte identity with
 * 7l, and so 7l's choices (pools, bitmask immediates, extended
 * registers); shifted operands, pre- and post-indexed addressing, CSEL
 * and the others 7c doesn't emit.
 *
 * The test: TinyAssembler_test.sh builds goken's exit and hello, and
 * goken's 17 hello_libc programs with all of libc, runs them, and
 * compares what they print with goken's expected outputs (two of them,
 * dirread and mem, pass here and fail with goken's own 7l).
 *
 * Usage: tinyassembler [-e entry] [-o out] file.s...
 *
 * References: M. V. Wilkes, D. J. Wheeler and S. Gill, The Preparation
 * of Programs for an Electronic Digital Computer (1951), the EDSAC
 * book: its initial orders read orders punched as a letter and a
 * decimal address from paper tape and put them into memory as binary,
 * assembling and loading in one step, as this does; Ken Thompson,
 * "Plan 9 C Compilers" (Summer 1990 UKUUG Conference), for the
 * encoding done where every address is known; T. G. Szymanski,
 * "Assembling Code for Machines with Span-dependent Instructions"
 * (CACM, 1978), the problem avoided by choosing each expansion from
 * its operands alone: no size waits for an address, so no pass is
 * redone; the Tool Interface Standard's ELF specification (1995). *)

exception Error of string

let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

(*****************************************************************************)
(* Lexing *)
(*****************************************************************************)

type tok = Id of string | Num of int64 | Flt of float | Str of string | P of char | Eol

let is_id c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_' || c = '.' || c >= '\x80'
let is_digit c = c >= '0' && c <= '9'

(* the tokens of a file, each with its line *)
let lex text =
  let n = String.length text and toks = ref [] and line = ref 1 in
  let add t = toks := (t, !line) :: !toks in
  let rec go i =
    if i < n then
      match text.[i] with
      | '\n' | ';' -> if text.[i] = '\n' then incr line; add Eol; go (i + 1)
      | ' ' | '\t' | '\r' -> go (i + 1)
      | '/' when i + 1 < n && text.[i + 1] = '/' -> go (try String.index_from text i '\n' with Not_found -> n)
      | '/' when i + 1 < n && text.[i + 1] = '*' ->
          let rec close j = if j + 1 >= n then n else if text.[j] = '*' && text.[j + 1] = '/' then j + 2 else (if text.[j] = '\n' then incr line; close (j + 1)) in
          go (close (i + 2))
      | '"' ->
          let b = Buffer.create 8 in
          let rec str j =
            match text.[j] with
            | '"' -> j + 1
            | '\\' ->
                let e = text.[j + 1] in
                if e >= '0' && e <= '7' then begin
                  let k = ref (j + 1) and v = ref 0 in
                  while !k < j + 4 && text.[!k] >= '0' && text.[!k] <= '7' do v := (8 * !v) + Char.code text.[!k] - 48; incr k done;
                  Buffer.add_char b (Char.chr (!v land 255));
                  str !k
                end
                else (Buffer.add_char b (match e with 'n' -> '\n' | 't' -> '\t' | 'r' -> '\r' | 'z' -> '\000' | c -> c); str (j + 2))
            | c -> Buffer.add_char b c; str (j + 1)
          in
          let j = str (i + 1) in
          add (Str (Buffer.contents b));
          go j
      | c when is_digit c ->
          let j = ref i in
          while !j < n && (is_id text.[!j] || ((text.[!j] = '+' || text.[!j] = '-') && (text.[!j - 1] = 'e' || text.[!j - 1] = 'E') && text.[i + 1] <> 'x')) do incr j done;
          let s = String.sub text i (!j - i) in
          if String.contains s '.' || (String.contains s 'e' && not (String.contains s 'x')) then add (Flt (float_of_string s))
          else add (Num (match Int64.of_string_opt s with Some v -> v | None -> Int64.of_string ("0u" ^ s)));
          go !j
      | c when is_id c ->
          (* a $ inside a name: 7c's static locals, x$7<> *)
          let j = ref i in
          while !j < n && (is_id text.[!j] || (text.[!j] = '$' && is_digit text.[!j + 1])) do incr j done;
          let j = if !j + 1 < n && text.[!j] = '<' && text.[!j + 1] = '>' then !j + 2 else !j in
          add (Id (String.sub text i (j - i)));
          go j
      | c -> add (P c); go (i + 1)
  in
  go 0;
  add Eol;
  List.rev !toks

(*****************************************************************************)
(* Parsing *)
(*****************************************************************************)

type base = R of int | SB | SP | FP

(* a name is global, or file<>name for a name<> *)
type opd =
  | Reg of int | FReg of int | Imm of int64 | Fimm of float | Str of string
  | Mem of base * string * int         (* name (or ""), offset *)
  | Addr of base * string * int        (* $ of the same *)
  | Target of int                      (* an instruction, by its number *)

type item =
  | Text of string * int                          (* name, frame *)
  | Ins of string * opd list
  | Globl of string * int
  | Data of string * int * int * opd              (* name, offset, width, value *)

let register s =
  let num p = if String.length s > 1 && s.[0] = p then int_of_string_opt (String.sub s 1 (String.length s - 1)) else None in
  match s, num 'R', num 'F' with
  | ("ZR" | "RSP"), _, _ -> Some (Reg 31)
  | "LR", _, _ -> Some (Reg 30)
  | _, Some r, _ when r <= 31 -> Some (Reg r)
  | _, _, Some f when f <= 31 -> Some (FReg f)
  | _ -> None

(* the items of the files, with their files and lines, and for TEXT
 * and the instructions their numbers, which n(PC) counts *)
let read_file (caps : < Cap.open_in; .. >) file =
  let ic = CapStdlib.open_in caps file in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> really_input_string ic (in_channel_length ic))

(* the executable, through the capability to write files *)
let write_exe (_ : < Cap.open_out; .. >) out (b : Bytes.t) =
  Out_channel.with_open_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o755 out (fun oc -> Out_channel.output_bytes oc b)

let parse caps files =
  let all = ref [] and count = ref 0 in
  List.iteri (fun fi file ->
    let items = ref [] and labels = Hashtbl.create 64 and pending = ref [] in
    (* a file's lines, each a list of tokens *)
    let rec lines acc cur = function
      | [] -> List.rev acc
      | (Eol, _) :: rest -> lines (if cur = [] then acc else List.rev cur :: acc) [] rest
      | t :: rest -> lines acc (t :: cur) rest
    in
    List.iter (fun toks ->
      let toks = ref toks in
      let line = match !toks with (_, l) :: _ -> l | [] -> 0 in
      let fail what = error "%s:%d: %s" file line what in
      let peek () = match !toks with (t, _) :: _ -> t | [] -> Eol in
      let next () = let t = peek () in (if !toks <> [] then toks := List.tl !toks); t in
      let expect c = if next () <> P c then fail (Printf.sprintf "expected %c" c) in
      let scope n = if String.ends_with ~suffix:"<>" n then string_of_int fi ^ n else n in
      let rec number () = match next () with P '-' -> Int64.neg (number ()) | P '+' -> number () | Num v -> v | _ -> fail "expected a number" in
      let offset () = match peek () with P ('+' | '-') | Num _ -> Int64.to_int (number ()) | _ -> 0 in
      let base () =
        expect '(';
        let b = match next () with
          | Id "SB" -> SB | Id "SP" -> SP | Id "FP" -> FP
          | Id r -> (match register r with Some (Reg r) -> R r | _ -> fail "bad base")
          | _ -> fail "bad base" in
        expect ')';
        b
      in
      (* a branch's target, resolved once the file's labels are known *)
      let target t = pending := (!count, t) :: !pending; Target 0 in
      let operand () =
        match next () with
        | P '$' -> (
            match peek () with
            | Str s -> ignore (next ()); Str s
            | Flt x -> ignore (next ()); Fimm x
            | P '-' when (match !toks with _ :: (Flt _, _) :: _ -> true | _ -> false) ->
                ignore (next ()); (match next () with Flt x -> Fimm (-. x) | _ -> fail "bad float")
            | Id n -> ignore (next ()); let o = offset () in let b = base () in Addr (b, scope n, o)
            | _ -> let v = number () in if peek () = P '(' then Addr (base (), "", Int64.to_int v) else Imm v)
        | Id n when register n <> None -> Option.get (register n)
        | Id n -> let o = offset () in if peek () = P '(' then (let b = base () in Mem (b, scope n, o)) else target (`Label n)
        | P '(' -> toks := (P '(', line) :: !toks; Mem (base (), "", 0)
        | t ->
            toks := (t, line) :: !toks;
            let v = Int64.to_int (number ()) in
            (match !toks with (P '(', _) :: (Id "PC", _) :: _ -> ignore (next ()); ignore (next ()); expect ')'; target (`Rel v)
             | (P '(', _) :: _ -> Mem (base (), "", v)
             | _ -> Imm (Int64.of_int v))
      in
      let rec operands () = let o = operand () in if peek () = P ',' then (ignore (next ()); o :: operands ()) else [ o ] in
      let emit it = items := (it, file, line, !count) :: !items; (match it with Text _ | Ins _ -> incr count | _ -> ()) in
      let rec statement () =
        match next () with
        | Id l when peek () = P ':' -> ignore (next ()); Hashtbl.replace labels l !count; if !toks <> [] then statement ()
        | Id "END" -> ()
        | Id "DATA" -> (
            match operand () with
            | Mem (SB, n, off) ->
                expect '/';
                let w = Int64.to_int (number ()) in
                expect ',';
                items := (Data (n, off, w, operand ()), file, line, !count) :: !items
            | _ -> fail "bad DATA")
        | Id ("TEXT" | "GLOBL" as d) -> (
            match operands () with
            | [ Mem (SB, n, _); Imm s ] | [ Mem (SB, n, _); _; Imm s ] ->
                emit (if d = "TEXT" then Text (n, Int64.to_int s) else Globl (n, Int64.to_int s))
            | _ -> fail ("bad " ^ d))
        | Id op -> emit (Ins (op, if !toks = [] then [] else operands ()))
        | _ -> fail "syntax error"
      in
      statement ();
      if !toks <> [] then fail "junk after the operands") (lines [] [] (lex (read_file caps file)));
    let resolve id = function
      | `Rel n -> id + n
      | `Label l -> (match Hashtbl.find_opt labels l with Some i -> i | None -> error "%s: undefined label %s" file l) in
    let targets = Hashtbl.create 64 in
    List.iter (fun (id, t) -> Hashtbl.replace targets id (resolve id t)) !pending;
    all := List.rev_map (fun ((it, f, l, id) as x) ->
      match it, Hashtbl.find_opt targets id with
      | Ins (op, args), Some t -> (Ins (op, List.map (function Target _ -> Target t | a -> a) args), f, l, id)
      | _ -> x) !items :: !all) files;
  List.concat (List.rev !all)

(*****************************************************************************)
(* Functions, data, and what the entry reaches *)
(*****************************************************************************)

type func = { name : string; frame : int; body : (item * int) list; where : string * int }

(* each function with its instructions (and their numbers), each data
 * symbol with its size and DATAs; the first definition of a name wins *)
let gather items =
  let funcs = Hashtbl.create 1024 and order = ref [] and sizes = Hashtbl.create 1024 and datas = ref [] in
  let cur = ref None in
  let close () = Option.iter (fun f ->
    if not (Hashtbl.mem funcs f.name) then (Hashtbl.replace funcs f.name { f with body = List.rev f.body }; order := f.name :: !order)) !cur in
  List.iter (fun (it, file, line, id) ->
    match it with
    | Text (name, frame) -> close (); cur := Some { name; frame; body = [ (it, id) ]; where = (file, line) }
    | Ins _ -> (match !cur with Some f -> cur := Some { f with body = (it, id) :: f.body } | None -> error "%s:%d: an instruction outside a TEXT" file line)
    | Globl (n, size) -> Hashtbl.replace sizes n (max size (Option.value (Hashtbl.find_opt sizes n) ~default:0))
    | Data (n, off, w, v) ->
        Hashtbl.replace sizes n (max (off + w) (Option.value (Hashtbl.find_opt sizes n) ~default:0));
        datas := (n, off, w, v) :: !datas) items;
  close ();
  funcs, List.rev !order, sizes, List.rev !datas

let names_of = List.filter_map (function Mem (SB, n, _) | Addr (SB, n, _) when n <> "" -> Some n | _ -> None)

(* the names reached from the entry, through code and data *)
let reach funcs sizes datas entry =
  let seen = Hashtbl.create 1024 and values = Hashtbl.create 1024 in
  List.iter (fun (n, _, _, v) -> Hashtbl.add values n v) datas;
  let rec visit n =
    if not (Hashtbl.mem seen n) then begin
      Hashtbl.replace seen n ();
      (match Hashtbl.find_opt funcs n with
       | Some f -> List.iter (function Ins (_, args), _ -> List.iter visit (names_of args) | _ -> ()) f.body
       | None -> if not (Hashtbl.mem sizes n) && not (List.mem n [ "setSB"; "etext"; "bdata"; "edata"; "end" ]) then error "undefined: %s" n);
      List.iter (fun v -> List.iter visit (names_of [ v ])) (Hashtbl.find_all values n)
    end
  in
  visit entry;
  seen

(*****************************************************************************)
(* Encoding: each instruction into words, functions of their pc *)
(*****************************************************************************)

type word = int -> int

let tmp = 17 and zr = 31 and sp = 31 and link = 30

(* the addresses, known after the layout: of names, of instructions *)
let addrs : (string, int) Hashtbl.t = Hashtbl.create 1024
let item_addrs : (int, int) Hashtbl.t = Hashtbl.create 8192

let addr n = match Hashtbl.find_opt addrs n with Some a -> a | None -> error "undefined: %s" n
let k w : word = fun _ -> w

(* a constant into rd: MOVZ or MOVN, then a MOVK per other 16 bits *)
let movconst sf rd (v : int64) =
  let n = if sf then 4 else 2 in
  let lane i = Int64.to_int (Int64.shift_right_logical v (16 * i)) land 0xffff in
  let lanes = List.init n lane in
  let count x = List.length (List.filter (( = ) x) lanes) in
  let inverted = count 0xffff > count 0 in
  let base = if inverted then 0xffff else 0 in
  let top = if sf then 1 lsl 31 else 0 in
  let first = try List.find (fun i -> lane i <> base) (List.init n Fun.id) with Not_found -> 0 in
  let lead = if inverted then 0x12800000 lor ((lnot (lane first) land 0xffff) lsl 5) else 0x52800000 lor (lane first lsl 5) in
  k (top lor lead lor (first lsl 21) lor rd)
  :: List.filter_map (fun i -> if i <> first && lane i <> base then Some (k (top lor 0x72800000 lor (i lsl 21) lor (lane i lsl 5) lor rd)) else None) (List.init n Fun.id)

(* ADD or SUB of an immediate of up to 24 bits (two instructions past 12) *)
let add_imm sf sub rd rn v =
  let op sh x rn = k ((if sf then 1 lsl 31 else 0) lor (if sub then 1 lsl 30 else 0) lor 0x11000000 lor (sh lsl 22) lor (x lsl 10) lor (rn lsl 5) lor rd) in
  if v >= 1 lsl 24 then error "an immediate of 24 bits or more: %#x" v
  else if v < 4096 then [ op 0 v rn ]
  else if v land 0xfff = 0 then [ op 1 (v lsr 12) rn ]
  else [ op 1 (v lsr 12) rn; op 0 (v land 0xfff) rd ]

(* an address, pc-relative: its page, then its offset in the page *)
let address rd (a : unit -> int) : word list =
  [ (fun pc -> let d = (a () asr 12) - (pc asr 12) in 0x90000000 lor ((d land 3) lsl 29) lor (((d asr 2) land 0x7ffff) lsl 5) lor rd);
    (fun _ -> 0x91000000 lor ((a () land 0xfff) lsl 10) lor (rd lsl 5) lor rd) ]

(* loads and stores: the size's log, the load, the store (unsigned
 * offset forms; the unscaled and register-offset ones derive) *)
let ldst = function
  | "MOV" -> 3, 0xF9400000, 0xF9000000 | "MOVW" -> 2, 0xB9800000, 0xB9000000 | "MOVWU" -> 2, 0xB9400000, 0xB9000000
  | "MOVH" -> 1, 0x79800000, 0x79000000 | "MOVHU" -> 1, 0x79400000, 0x79000000
  | "MOVB" -> 0, 0x39800000, 0x39000000 | "MOVBU" -> 0, 0x39400000, 0x39000000
  | "FMOVD" -> 3, 0xFD400000, 0xFD000000 | "FMOVS" -> 2, 0xBD400000, 0xBD000000
  | op -> error "no load or store %s" op

let access op load rt b o =
  let s, l, st = ldst op in
  let opc = if load then l else st in
  if o >= 0 && o land ((1 lsl s) - 1) = 0 && o lsr s < 4096 then [ k (opc lor ((o lsr s) lsl 10) lor (b lsl 5) lor rt) ]
  else if o >= -256 && o < 256 then [ k ((opc land lnot (1 lsl 24)) lor ((o land 0x1ff) lsl 12) lor (b lsl 5) lor rt) ]
  else movconst true tmp (Int64.of_int o) @ [ k ((opc land lnot (1 lsl 24)) lor (1 lsl 21) lor (tmp lsl 16) lor (3 lsl 13) lor (2 lsl 10) lor (b lsl 5) lor rt) ]

let conds = [ "EQ", 0; "NE", 1; "CS", 2; "HS", 2; "CC", 3; "LO", 3; "MI", 4; "PL", 5; "VS", 6; "VC", 7; "HI", 8; "LS", 9;
              "GE", 10; "LT", 11; "GT", 12; "LE", 13 ]

(* a W at the end: the 32-bit form *)
let width op = if String.length op > 1 && op.[String.length op - 1] = 'W' && not (List.mem op [ "MOVW"; "SXTW"; "UXTW" ]) then String.sub op 0 (String.length op - 1), false else op, true

let fconv = [ "FCVTDS", 0x1E624000; "FCVTSD", 0x1E22C000; "SCVTFD", 0x9E620000; "SCVTFWD", 0x1E620000; "SCVTFS", 0x9E220000;
              "SCVTFWS", 0x1E220000; "UCVTFD", 0x9E630000; "UCVTFWD", 0x1E630000; "UCVTFS", 0x9E230000; "UCVTFWS", 0x1E230000;
              "FCVTZSD", 0x9E780000; "FCVTZSDW", 0x1E780000; "FCVTZSS", 0x9E380000; "FCVTZSSW", 0x1E380000;
              "FCVTZUD", 0x9E790000; "FCVTZUDW", 0x1E790000; "FCVTZUS", 0x9E390000; "FCVTZUSW", 0x1E390000 ]

type fctx = { autosize : int; leaf : bool; mutable lastcase : int }

let target = function
  | Target id -> (fun () -> match Hashtbl.find_opt item_addrs id with Some a -> a | None -> error "a branch out of the program")
  | Mem (SB, n, o) -> (fun () -> addr n + o)
  | _ -> error "bad branch target"

let branch base bits shift t : word = fun pc -> base lor ((((t () - pc) asr 2) land ((1 lsl bits) - 1)) lsl shift)

(* a frame operand's offset from SP *)
let frame_off c b o = match b with SP -> c.autosize + o | FP -> c.autosize + 8 + o | _ -> o
let reg = function Reg r | FReg r -> r | Imm 0L -> zr | _ -> error "expected a register"

let compile c op args : word list =
  let base, sf = width op in
  let top = if sf then 1 lsl 31 else 0 in
  (* the operands: (from, middle, to), the middle defaulting to to *)
  let three = function [ a; d ] -> a, reg d, reg d | [ a; n; d ] -> a, reg n, reg d | _ -> error "%s: bad operands" op in
  match base, args with
  (* moves, loads and stores *)
  | ("MOV" | "MOVW" | "MOVWU" | "MOVH" | "MOVHU" | "MOVB" | "MOVBU" | "FMOVD" | "FMOVS"), [ a; b ] -> (
      match a, b with
      | (Reg _ | FReg _ | Imm 0L), Mem (SB, n, o) -> address tmp (fun () -> addr n + o) @ access op false (reg a) tmp 0
      | (Reg _ | FReg _ | Imm 0L), Mem (bs, _, o) -> access op false (reg a) (match bs with R r -> r | _ -> sp) (frame_off c bs o)
      | Mem (SB, n, o), _ -> address tmp (fun () -> addr n + o) @ access op true (reg b) tmp 0
      | Mem (bs, _, o), _ -> access op true (reg b) (match bs with R r -> r | _ -> sp) (frame_off c bs o)
      | Addr (SB, n, o), Reg d -> address d (fun () -> addr n + o)
      | Addr (bs, _, o), Reg d -> add_imm true false d (match bs with R r -> r | _ -> sp) (frame_off c bs o)
      | Imm v, Reg d -> movconst (op = "MOV") d (if op = "MOV" then v else Int64.logand v 0xffffffffL)
      | Fimm x, FReg d ->
          if op = "FMOVD" then movconst true tmp (Int64.bits_of_float x) @ [ k (0x9E670000 lor (tmp lsl 5) lor d) ]
          else movconst false tmp (Int64.of_int32 (Int32.bits_of_float x)) @ [ k (0x1E270000 lor (tmp lsl 5) lor d) ]
      | FReg f, FReg d -> [ k ((if op = "FMOVD" then 0x1E604000 else 0x1E204000) lor (f lsl 5) lor d) ]
      | Reg f, Reg d ->
          [ k (match op with
               | "MOV" when f = sp || d = sp -> 0x91000000 lor (f lsl 5) lor d
               | "MOV" -> 0xAA0003E0 lor (f lsl 16) lor d
               | "MOVWU" -> 0x2A0003E0 lor (f lsl 16) lor d
               | "MOVW" -> 0x93407C00 lor (f lsl 5) lor d | "MOVH" -> 0x93403C00 lor (f lsl 5) lor d
               | "MOVHU" -> 0xD3403C00 lor (f lsl 5) lor d | "MOVB" -> 0x93401C00 lor (f lsl 5) lor d
               | _ -> 0xD3401C00 lor (f lsl 5) lor d) ]
      | _ -> error "%s: bad operands" op)
  | ("SXTW" | "SXTH" | "SXTB" | "UXTW" | "UXTH" | "UXTB"), [ Reg f; Reg d ] ->
      [ k (List.assoc op [ "SXTW", 0x93407C00; "SXTH", 0x93403C00; "SXTB", 0x93401C00; "UXTW", 0xD3407C00; "UXTH", 0xD3403C00; "UXTB", 0xD3401C00 ]
           lor (f lsl 5) lor d) ]
  (* arithmetic: register, or an immediate made to fit *)
  | ("ADD" | "SUB" | "ADDS" | "SUBS" | "CMP" | "CMN"), _ ->
      let a, n, d = match base, args with ("CMP" | "CMN"), [ a; n ] -> a, reg n, zr | _ -> three args in
      let flags = base <> "ADD" && base <> "SUB" in
      let sub = List.mem base [ "SUB"; "SUBS"; "CMP" ] in
      let rr sub rm = k (top lor (if sub then 1 lsl 30 else 0) lor (if flags then 1 lsl 29 else 0) lor 0x0B000000 lor (rm lsl 16) lor (n lsl 5) lor d) in
      (match a with
       | Reg m -> [ rr sub m ]
       | Imm v ->
           let sub, v = if v < 0L then not sub, Int64.neg v else sub, v in
           let v = Int64.to_int v in
           if v < 4096 || (v land 0xfff = 0 && v < 1 lsl 24) || (not flags && v < 1 lsl 24) then
             List.map (fun w pc -> w pc lor (if flags then 1 lsl 29 else 0)) (add_imm sf sub d n v)
           else if not flags && (n = sp || d = sp) then
             movconst sf tmp (Int64.of_int v) @ [ k (top lor (if sub then 1 lsl 30 else 0) lor 0x0B200000 lor (tmp lsl 16) lor ((if sf then 3 else 2) lsl 13) lor (n lsl 5) lor d) ]
           else movconst sf tmp (Int64.of_int v) @ [ rr sub tmp ]
       | _ -> error "%s: bad operands" op)
  | ("AND" | "ORR" | "EOR" | "ANDS" | "BIC" | "ORN" | "EON" | "BICS" | "TST"), _ ->
      let a, n, d = if base = "TST" then (match args with [ a; n ] -> a, reg n, zr | _ -> error "bad TST") else three args in
      let opc, neg = List.assoc (if base = "TST" then "ANDS" else base)
          [ "AND", (0, 0); "ORR", (1, 0); "EOR", (2, 0); "ANDS", (3, 0); "BIC", (0, 1); "ORN", (1, 1); "EON", (2, 1); "BICS", (3, 1) ] in
      let rr m = k (top lor (opc lsl 29) lor 0x0A000000 lor (neg lsl 21) lor (m lsl 16) lor (n lsl 5) lor d) in
      (match a with
       | Reg m -> [ rr m ]
       | Imm v -> movconst sf tmp (if sf then v else Int64.logand v 0xffffffffL) @ [ rr tmp ]
       | _ -> error "%s: bad operands" op)
  | ("NEG" | "MVN"), [ Reg m; Reg d ] -> [ k (top lor (if base = "NEG" then 0x4B0003E0 else 0x2A2003E0) lor (m lsl 16) lor d) ]
  | ("LSL" | "LSR" | "ASR"), _ -> (
      let a, n, d = three args in
      let w = if sf then 64 else 32 in
      match a with
      | Imm v ->
          let v = Int64.to_int v in
          let immr, imms = if base = "LSL" then (w - v) land (w - 1), w - 1 - v else v, w - 1 in
          [ k ((if base = "ASR" then (if sf then 0x93400000 else 0x13000000) else if sf then 0xD3400000 else 0x53000000)
               lor (immr lsl 16) lor (imms lsl 10) lor (n lsl 5) lor d) ]
      | Reg m -> [ k (top lor List.assoc base [ "LSL", 0x1AC02000; "LSR", 0x1AC02400; "ASR", 0x1AC02800 ] lor (m lsl 16) lor (n lsl 5) lor d) ]
      | _ -> error "%s: bad operands" op)
  | ("MUL" | "UMULL" | "SMULL" | "SDIV" | "UDIV"), _ ->
      let a, n, d = three args in
      let o = match base with "MUL" -> top lor 0x1B007C00 | "UMULL" -> 0x9BA07C00 | "SMULL" -> 0x9B207C00
                              | "SDIV" -> top lor 0x1AC00C00 | _ -> top lor 0x1AC00800 in
      [ k (o lor (reg a lsl 16) lor (n lsl 5) lor d) ]
  | ("REM" | "UREM"), _ ->
      (* the quotient, then the remainder by MSUB *)
      let a, n, d = three args in
      [ k (top lor (if base = "REM" then 0x1AC00C00 else 0x1AC00800) lor (reg a lsl 16) lor (n lsl 5) lor tmp);
        k (top lor 0x1B008000 lor (reg a lsl 16) lor (n lsl 10) lor (tmp lsl 5) lor d) ]
  (* branches *)
  | ("B" | "BL"), [ Mem (R r, _, _) ] -> [ k ((if op = "B" then 0xD61F0000 else 0xD63F0000) lor (r lsl 5)) ]
  | ("B" | "BL"), [ t ] -> [ branch (if op = "B" then 0x14000000 else 0x94000000) 26 0 (target t) ]
  | _, [ t ] when String.length op = 3 && op.[0] = 'B' && List.mem_assoc (String.sub op 1 2) conds ->
      [ branch (0x54000000 lor List.assoc (String.sub op 1 2) conds) 19 5 (target t) ]
  | ("CBZ" | "CBNZ"), [ Reg r; t ] -> [ branch (top lor (if base = "CBZ" then 0x34000000 else 0x35000000) lor r) 19 5 (target t) ]
  | "RET", [] -> [ k 0xD65F03C0 ]
  | "RET", [ Mem (R r, _, _) ] | "RET", [ Reg r ] -> [ k (0xD65F0000 lor (r lsl 5)) ]
  | "RETURN", [] ->
      let ret = k 0xD65F03C0 in
      if c.leaf then (if c.autosize = 0 then [ ret ] else add_imm true false sp sp c.autosize @ [ ret ])
      else
        let pop = min c.autosize 0xf0 in
        (* LDR R30, [SP], #pop *)
        k (0xF8400400 lor ((pop land 0x1ff) lsl 12) lor (sp lsl 5) lor link)
        :: (if c.autosize > pop then add_imm true false sp sp (c.autosize - pop) else []) @ [ ret ]
  | "SVC", ([] | [ Imm _ ]) -> [ k (0xD4000001 lor (match args with [ Imm v ] -> (Int64.to_int v land 0xffff) lsl 5 | _ -> 0)) ]
  (* a switch: the table of offsets that follows, at CASE+16 *)
  | "CASE", [ Reg v; Reg t ] ->
      [ k (0x10000000 lor (4 lsl 5) lor t);
        k (0xB8A07800 lor (v lsl 16) lor (t lsl 5) lor tmp);
        k (0x8B000000 lor (t lsl 16) lor (tmp lsl 5) lor tmp);
        k (0xD61F0000 lor (tmp lsl 5)) ]
  | "BCASE", [ t ] ->
      let case = c.lastcase in
      [ (fun _ -> (target t () - (Hashtbl.find item_addrs case + 16)) land 0xffffffff) ]
  (* floating point *)
  | ("FADDD" | "FSUBD" | "FMULD" | "FDIVD" | "FADDS" | "FSUBS" | "FMULS" | "FDIVS"), _ ->
      let a, n, d = three args in
      let o = List.assoc (String.sub op 0 4) [ "FADD", 0x1E202800; "FSUB", 0x1E203800; "FMUL", 0x1E200800; "FDIV", 0x1E201800 ] in
      [ k (o lor (if op.[4] = 'D' then 0x400000 else 0) lor (reg a lsl 16) lor (n lsl 5) lor d) ]
  | ("FCMPD" | "FCMPS"), [ a; n ] -> [ k ((if op = "FCMPD" then 0x1E602000 else 0x1E202000) lor (reg a lsl 16) lor (reg n lsl 5)) ]
  | _, [ a; d ] when List.mem_assoc op fconv -> [ k (List.assoc op fconv lor (reg a lsl 5) lor reg d) ]
  | _ -> error "%s: not in the subset, or bad operands" op

(* a function's frame (7l's noops), its prologue, and its instructions *)
let expand (f : func) =
  let leaf = not (List.exists (function Ins ("BL", _), _ -> true | _ -> false) f.body) in
  let a = if f.frame < 0 then 0 else ((f.frame + 7) land lnot 7) + 8 in
  let a = if leaf && a <= 8 then 0 else (a + 15) land lnot 15 in
  let leaf = leaf || a = 0 in
  let c = { autosize = a; leaf; lastcase = 0 } in
  let push = if leaf then 0 else min a 0xf0 in
  List.map (fun (it, id) ->
    id, match it with
    | Text _ ->
        (if a > push then add_imm true true sp sp (a - push) else [])
        (* STR R30, [SP, #-push]! *)
        @ if leaf then [] else [ k (0xF8000C00 lor ((- push land 0x1ff) lsl 12) lor (sp lsl 5) lor link) ]
    | Ins (op, args) -> if op = "CASE" then c.lastcase <- id; (try compile c op args with Error m -> let fl, l = f.where in error "%s (in %s, from %s:%d)" m f.name fl l)
    | _ -> []) f.body

(*****************************************************************************)
(* Layout, data, and the ELF file *)
(*****************************************************************************)

let base_addr = 0x400000 and headr = 64 + 56

let link (caps : < Cap.open_in; Cap.open_out; .. >) files entry out =
  let funcs, order, sizes, datas = gather (parse caps files) in
  let live = reach funcs sizes datas entry in
  (* the text: the reached functions, in their files' order *)
  let code = List.concat_map (fun n -> if Hashtbl.mem live n then [ n, expand (Hashtbl.find funcs n) ] else []) order in
  let pc = ref (base_addr + headr) in
  List.iter (fun (n, items) ->
    Hashtbl.replace addrs n !pc;
    List.iter (fun (id, ws) -> Hashtbl.replace item_addrs id !pc; pc := !pc + (4 * List.length ws)) items) code;
  let etext = !pc in
  (* the data, then the bss, each symbol 8-aligned, in their order *)
  let data_start = (etext + 15) land lnot 15 in
  let has_data = Hashtbl.create 64 in
  List.iter (fun (n, _, _, _) -> Hashtbl.replace has_data n ()) datas;
  let syms = Hashtbl.fold (fun n _ acc -> if Hashtbl.mem live n && not (Hashtbl.mem funcs n) then n :: acc else acc) sizes [] |> List.sort compare in
  let place = List.fold_left (fun off n -> Hashtbl.replace addrs n (data_start + off); (off + Hashtbl.find sizes n + 7) land lnot 7) in
  let dsize = place 0 (List.filter (Hashtbl.mem has_data) syms) in
  let bsize = place dsize (List.filter (fun n -> not (Hashtbl.mem has_data n)) syms) - dsize in
  List.iter (fun (n, v) -> Hashtbl.replace addrs n v)
    [ "setSB", data_start; "bdata", data_start; "etext", etext; "edata", data_start + dsize; "end", data_start + dsize + bsize ];
  (* the bytes *)
  let file = Bytes.make (data_start - base_addr + dsize) '\000' in
  List.iter (fun (_, items) ->
    List.iter (fun (id, ws) -> List.iteri (fun i w -> let a = Hashtbl.find item_addrs id + (4 * i) in
      Bytes.set_int32_le file (a - base_addr) (Int32.of_int (w a))) ws) items) code;
  List.iter (fun (n, off, w, v) ->
    if Hashtbl.mem live n then begin
      let a = addr n + off - base_addr in
      let int x = for i = 0 to w - 1 do Bytes.set file (a + i) (Char.chr (Int64.to_int (Int64.shift_right_logical x (8 * i)) land 255)) done in
      match v with
      | Imm x -> int x
      | Addr (SB, s, o) -> int (Int64.of_int (addr s + o))
      | Fimm x -> int (if w = 4 then Int64.of_int32 (Int32.bits_of_float x) else Int64.bits_of_float x)
      | Str s -> Bytes.blit_string s 0 file a (min w (String.length s))
      | _ -> error "DATA %s: a bad value" n
    end) datas;
  (* the header: ELF64, one PT_LOAD for all *)
  let h = Buffer.create headr in
  let w16 = Buffer.add_uint16_le h and w32 x = Buffer.add_int32_le h (Int32.of_int x) and w64 x = Buffer.add_int64_le h (Int64.of_int x) in
  Buffer.add_string h "\127ELF\002\001\001\000\000\000\000\000\000\000\000\000";
  w16 2; w16 183; w32 1; w64 (addr entry); w64 64; w64 0; w32 0; w16 64; w16 56; w16 1; w16 0; w16 0; w16 0;
  w32 1; w32 7; w64 0; w64 base_addr; w64 base_addr; w64 (Bytes.length file); w64 (Bytes.length file + bsize); w64 0x1000;
  Bytes.blit (Buffer.to_bytes h) 0 file 0 headr;
  write_exe caps out file

let main (caps : < Cap.argv; Cap.open_in; Cap.open_out; Cap.stderr; .. >) =
  let eprint (_ : < Cap.stderr; .. >) s = prerr_endline s in
  let rec args entry out files = function
    | "-e" :: e :: rest -> args e out files rest
    | "-o" :: o :: rest -> args entry o files rest
    | f :: rest -> args entry out (f :: files) rest
    | [] -> entry, out, List.rev files
  in
  match args "_main" "a.out" [] (List.tl (Array.to_list (CapSys.argv caps))) with
  | _, _, [] -> eprint caps "usage: tinyassembler [-e entry] [-o out] file.s..."; 1
  | entry, out, files -> (
      try link caps files entry out; 0 with Error m | Sys_error m -> eprint caps ("tinyassembler: " ^ m); 1)

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
