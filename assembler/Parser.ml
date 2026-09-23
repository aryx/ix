(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Parser.mli *)

open Asm
module L = Lexer

exception Error of int * string

(* arm64's condition names, as operands (CSEL, CSET...) *)
let conditions = [ "EQ"; "NE"; "HS"; "CS"; "LO"; "CC"; "MI"; "PL"; "VS"; "VC"; "HI"; "LS"; "GE"; "LT"; "GT"; "LE"; "AL"; "NV" ]

type state = {
  arch : arch;
  mutable toks : (L.token * int) list;
  consts : (string, int64) Hashtbl.t;       (* name = expr *)
  labels : (string, int) Hashtbl.t;         (* name: -> its pc *)
  mutable pc : int;
  mutable fixups : (int * (string * int)) list;  (* Target (-id): a label, and an offset *)
  mutable next_fix : int;
}

let line st = match st.toks with (_, l) :: _ -> l | [] -> 0
let error st msg = raise (Error (line st, msg))
let peek st = match st.toks with (t, _) :: _ -> t | [] -> L.Eol
let peek2 st = match st.toks with _ :: (t, _) :: _ -> t | _ -> L.Eol
let next st = match st.toks with (t, _) :: rest -> st.toks <- rest; t | [] -> L.Eol
let accept st p = if peek st = L.Punct p then (ignore (next st); true) else false
let expect st p = if not (accept st p) then error st ("expected " ^ p)

(* expressions: numbers, constants, 'c', unary - ~ +, binary * / % + - << >> & ^ |, ( ) *)
let rec expr st = binary st 0

and binary st level =
  let ops = [| [ "|" ]; [ "^" ]; [ "&" ]; [ "<<"; ">>" ]; [ "+"; "-" ]; [ "*"; "/"; "%" ] |] in
  if level = Array.length ops then unary st
  else begin
    let v = ref (binary st (level + 1)) in
    let rec loop () =
      match peek st with
      | L.Punct p when List.mem p ops.(level) ->
          ignore (next st);
          let w = binary st (level + 1) in
          v := (match p with
            | "|" -> Int64.logor !v w | "^" -> Int64.logxor !v w | "&" -> Int64.logand !v w
            | "<<" -> Int64.shift_left !v (Int64.to_int w) | ">>" -> Int64.shift_right !v (Int64.to_int w)
            | "+" -> Int64.add !v w | "-" -> Int64.sub !v w | "*" -> Int64.mul !v w
            | "/" -> Int64.div !v w | _ -> Int64.rem !v w);
          loop ()
      | _ -> ()
    in
    loop ();
    !v
  end

and unary st =
  match next st with
  | L.Punct "-" -> Int64.neg (unary st)
  | L.Punct "+" -> unary st
  | L.Punct "~" -> Int64.lognot (unary st)
  | L.Punct "(" -> let v = expr st in expect st ")"; v
  | L.Int v -> v
  | L.Ident s when Hashtbl.mem st.consts s -> Hashtbl.find st.consts s
  | _ -> error st "expected a number"

(* a ( that opens a base, (R1) (SB) ..., not an expression *)
let opens_base st =
  peek st = L.Punct "("
  && (match peek2 st with L.Ident ("SB" | "FP" | "PC" | "SP" | "R") -> true | L.Ident s -> register st.arch s <> None | _ -> false)

let reg st = match next st with L.Ident s -> (match register st.arch s with Some (Reg r) -> r | _ -> error st ("not a register: " ^ s)) | _ -> error st "expected a register"

(* R1<<2, R1>>R2, R1->3, R1@>4 *)
let shift_after st r =
  match peek st with
  | L.Punct (("<<" | ">>" | "->" | "@>") as p) ->
      ignore (next st);
      let kind = match p with "<<" -> 0 | ">>" -> 1 | "->" -> 2 | _ -> 3 in
      let by = match peek st with
        | L.Ident s when (match register st.arch s with Some (Reg _) -> true | _ -> false) -> `Reg (reg st)
        | _ -> `Imm (Int64.to_int (unary st))
      in
      Some { reg = r; kind; by }
  | _ -> None

(* (R1) (SB) (FP) (SP) (PC) *)
let base st =
  expect st "(";
  let b = match next st with
    | L.Ident "R" when peek st = L.Punct "(" -> expect st "("; let r = Int64.to_int (expr st) in expect st ")"; R r
    | L.Ident "SB" -> SB | L.Ident "FP" -> FP | L.Ident "PC" -> PC
    | L.Ident "SP" when st.arch = Arm64 -> SP
    | L.Ident "SP" -> SP
    | L.Ident s -> (match register st.arch s with Some (Reg r) -> R r | _ -> error st ("bad base " ^ s))
    | _ -> error st "expected a base register"
  in
  expect st ")";
  b

(* an optional (R2) or (R2<<3) after a memory reference: an index *)
let index st =
  match st.toks with
  | (L.Punct "(", _) :: (L.Ident s, _) :: _ when (match register st.arch s with Some (Reg _) -> true | _ -> false) ->
      ignore (next st);
      let r = reg st in
      let s = match shift_after st r with Some s -> s | None -> { reg = r; kind = 0; by = `Imm 0 } in
      expect st ")";
      Some s
  | _ -> None

(* name<>+off(SB), name+off(FP), or a label *)
let named st s =
  let static = accept st "<>" in
  let off = match peek st with L.Punct ("+" | "-") -> expr st | _ -> 0L in
  if peek st = L.Punct "(" then `Mem { base = base st; name = Some { sym = s; static }; off; index = None }
  else `Label (s, off)

let rec operand st : operand =
  match peek st with
  | L.Punct "$" -> (
      ignore (next st);
      match peek st with
      | L.String s -> ignore (next st); Str s
      | L.Float x -> ignore (next st); Fimm x
      | L.Punct "-" when (match peek2 st with L.Float _ -> true | _ -> false) ->
          ignore (next st); (match next st with L.Float x -> Fimm (-. x) | _ -> assert false)
      | L.Ident s when not (Hashtbl.mem st.consts s) -> (
          ignore (next st);
          match named st s with `Mem m -> Addr m | `Label _ -> error st ("$" ^ s ^ ": no (SB)"))
      | _ ->
          let v = expr st in
          if peek st = L.Punct "(" then Addr { base = base st; name = None; off = v; index = None } else Imm v)
  | L.Punct "[" ->
      ignore (next st);
      let rec regs acc =
        let r = reg st in
        let acc = if accept st "-" then (let r2 = reg st in List.rev_append (List.init (r2 - r + 1) (fun i -> r + i)) acc) else r :: acc in
        if accept st "," then regs acc else (expect st "]"; List.sort_uniq compare acc)
      in
      Regs (regs [])
  | L.Punct "(" when (match peek2 st with L.Ident s -> (match register st.arch s with Some (Reg _) -> true | _ -> false) | _ -> false)
                     && (match st.toks with _ :: _ :: (L.Punct ",", _) :: _ -> true | _ -> false) ->
      ignore (next st);
      let a = reg st in
      expect st ",";
      let b = reg st in
      expect st ")";
      Pair (a, b)
  (* R(expr), with a constant: 5a's R(Q) *)
  | L.Ident "R" when peek2 st = L.Punct "(" ->
      ignore (next st);
      expect st "(";
      let r = Int64.to_int (expr st) in
      expect st ")";
      Reg r
  | L.Ident s when register st.arch s <> None -> (
      ignore (next st);
      match register st.arch s with
      | Some (Reg r) -> (
          match shift_after st r with
          | Some sh when peek st = L.Punct "(" ->
              (* R2<<2(R1): a shifted index *)
              let b = base st in
              Mem { base = b; name = None; off = 0L; index = Some sh }
          | Some sh -> Shifted sh
          | None -> Reg r)
      | Some o -> o
      | None -> assert false)
  | L.Ident s when List.mem s conditions -> ignore (next st); Special s
  | L.Ident s when not (Hashtbl.mem st.consts s) -> (
      ignore (next st);
      match named st s with
      | `Mem m -> let ix = index st in Mem { m with index = ix }
      | `Label (l, off) ->
          (* resolved when the labels are all known *)
          st.next_fix <- st.next_fix + 1;
          st.fixups <- (st.next_fix, (l, Int64.to_int off)) :: st.fixups;
          Target (- st.next_fix))
  | _ ->
      let off = if opens_base st then 0L else expr st in
      (* a bare number: TEXT's flag, a count *)
      if peek st <> L.Punct "(" then Imm off else
      let b = base st in
      match b with
      | PC -> Target (st.pc + Int64.to_int off)
      | _ -> let ix = index st in Mem { base = b; name = None; off; index = ix }

and operands st =
  if peek st = L.Eol then []
  else begin
    let o = operand st in
    if accept st "," then o :: operands st else [ o ]
  end

let flag_and_size st =
  (* TEXT f(SB), [flag,] $size *)
  match operands st with
  | [ Imm size ] -> (0, size)
  | [ Imm flag; Imm size ] -> (Int64.to_int flag, size)
  | _ -> error st "bad TEXT or GLOBL"

let named_sym st =
  match next st with
  | L.Ident s -> (
      match named st s with
      | `Mem { base = SB; name = Some n; off; _ } -> (n, off)
      | _ -> error st "expected name(SB)")
  | _ -> error st "expected a name"

(* the items of a file, and their lines *)
let parse caps (arch : arch) (file : string) (text : string) : obj =
  let text = try L.preprocess caps (Filename.dirname file) text with Sys_error m -> raise (Error (0, m)) in
  let toks = try L.tokens text with L.Error (l, m) -> raise (Error (l, m)) in
  let st = { arch; toks; consts = Hashtbl.create 8; labels = Hashtbl.create 64; pc = 0; fixups = []; next_fix = 0 } in
  let items = ref [] in
  let add item l = items := (item, l) :: !items; (match item with Globl _ | Data _ -> () | _ -> st.pc <- st.pc + 1) in
  let rec lines () =
    let l = line st in
    match next st with
    | L.Eol -> if st.toks <> [] then lines ()
    | L.Ident s when peek st = L.Punct ":" -> ignore (next st); Hashtbl.replace st.labels s st.pc; lines ()
    | L.Ident s when peek st = L.Punct "=" -> ignore (next st); Hashtbl.replace st.consts s (expr st); lines ()
    | L.Ident "TEXT" ->
        let n, _ = named_sym st in
        expect st ",";
        let flag, size = flag_and_size st in
        add (Text (n, flag, size)) l; lines ()
    | L.Ident "GLOBL" ->
        let n, _ = named_sym st in
        expect st ",";
        let flag, size = flag_and_size st in
        add (Globl (n, flag, size)) l; lines ()
    | L.Ident "DATA" ->
        let n, off = named_sym st in
        expect st "/";
        let w = Int64.to_int (unary st) in
        expect st ",";
        let v = operand st in
        add (Data (n, off, w, v)) l; lines ()
    | L.Ident "END" -> lines ()
    | L.Ident op ->
        let parts = String.split_on_char '.' op in
        let args = operands st in
        if peek st <> L.Eol then error st "junk after the operands";
        add (Ins { op = List.hd parts; suffixes = List.tl parts; args }) l;
        lines ()
    | _ -> error st "expected an instruction"
  in
  (try lines () with L.Error (l, m) -> raise (Error (l, m)));
  let items = Array.of_list (List.rev !items) in
  (* pc -> item index: GLOBL and DATA have no pc *)
  let of_pc = Hashtbl.create 64 in
  let pc = ref 0 in
  Array.iteri (fun i (it, _) -> match it with Globl _ | Data _ -> () | _ -> Hashtbl.replace of_pc !pc i; incr pc) items;
  let target l n =
    let p =
      if n >= 0 then n
      else begin
        let name, off = List.assoc (- n) st.fixups in
        match Hashtbl.find_opt st.labels name with
        | Some p -> p + off
        | None -> raise (Error (l, "undefined label " ^ name))
      end
    in
    match Hashtbl.find_opt of_pc p with Some i -> Target i | None -> raise (Error (l, Printf.sprintf "branch out of the file (pc %d)" p))
  in
  let items = Array.map (fun (it, l) ->
    match it with
    | Ins i -> (Ins { i with args = List.map (function Target n -> target l n | o -> o) i.args }, l)
    | _ -> (it, l)) items in
  { arch; file; items }
