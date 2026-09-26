(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Regs.mli *)

open Tree
open Emit
module A = Ix_asm.Asm

(*****************************************************************************)
(* The machine, as the code generator sees it *)
(*****************************************************************************)

(* what gopcode makes: an operator's instruction, 7c's negation and
 * complement, a call, a switch's table *)
type gop = Op of binop | Gneg | Gcom | Gcall | Gcase

(* the registers are numbered as 5c's: the integer ones, then the
 * floating ones from nreg *)
type backend = {
  nreg : int;
  nfreg : int;
  regret : int;                       (* the result, and the first argument *)
  fregret : int;
  regsp : int;
  reserved : int list;                (* never allocated: SB, SP, the linker's temporary... *)
  regtmp : int;                       (* regnode's: a register only for its type *)
  word : int;                         (* an argument's slot above the return address *)
  float_from_last : bool;             (* the float registers rotate as the integer ones (7c) *)
  ret : string;                       (* RET, RETURN *)
  zero_reg : int option;              (* a constant 0 as a register (7c's raddr) *)
  gmove : expr -> expr -> unit;
  gmover : expr -> expr -> unit;
  gopcode : gop -> bool -> expr option -> expr option -> expr option -> unit;
}

let be : backend option ref = ref None
let bk () = Option.get !be

(*****************************************************************************)
(* Operands of registers, comparisons, returns (txt.c) *)
(*****************************************************************************)

(* the register of a node, as a second source (txt.c's raddr) *)
let raddr (n : expr option) (q : prog) =
  match Option.map naddr n with
  | Some (A.Imm 0L) when (bk ()).zero_reg <> None -> q.reg <- (bk ()).zero_reg
  | Some (A.Reg r) | Some (A.FReg r) -> q.reg <- Some r
  | _ -> ignore (diag n "bad in raddr")

(* a load's or a store's operand, and a move to itself *)
let is_mem (n : expr) = match n.e with Name _ | Indreg _ | Unary (Ind, _) -> true | _ -> false
let samaddr (f : expr) (t : expr) = match f.e, t.e with Reg a, Reg b -> a = b | _ -> false

(* a comparison, both machines': a negative constant compared by CMN,
 * unless small says its negation overflows *)
let gcmp cmp ~fd ~small (f1 : expr option) f2 =
  let q = nextpc () in
  q.as_ <- cmp;
  q.from <- naddr_opt f1;
  (match f1, q.from with
   | Some { e = Const _; _ }, Some (A.Imm v) when not fd && Int64.compare v 0L < 0 && not (small v) ->
       q.as_ <- "CMN" ^ String.sub cmp 3 (String.length cmp - 3);
       q.from <- Some (A.Imm (Int64.neg v))
   | _ -> ());
  raddr f2 q

(* the branch of a relation; a float's not taken on a NaN when tr, the
 * branch taken if true *)
let grel o ~fd ~tr =
  let c : A.cond =
    match o with
    | Eq -> EQ | Ne -> NE
    | Lt -> if fd && not tr then MI else LT
    | Le -> if fd && not tr then LS else LE
    | Ge -> if fd && tr then PL else GE
    | Gt -> if fd && tr then HI else GT
    | Lo -> LO | Ls -> LS | Hs -> HS | Hi -> HI
    | Add | Sub | Mul | Div | Mod | Lmul | Ldiv | Lmod | And | Or | Xor | Ashl | Ashr | Lshr | Andand | Oror | Comma ->
        invalid_arg "grel: not a relation"
  in
  (nextpc ()).as_ <- "B" ^ A.string_of_cond c

let greturn () = let q = nextpc () in q.as_ <- (bk ()).ret; q

(*****************************************************************************)
(* Nodes the generator makes (txt.c's ginit) *)
(*****************************************************************************)


let nodreg (nn : expr) r = { e = Reg r; t = nn.t; line = nn.line; complex = 0; addable = Areg }

let regnode () = { (mk ~t:(ty Tlong) (Reg (bk ()).regtmp)) with addable = Areg }

let reg_of (n : expr) = match n.e with Reg r | Indreg (r, _) -> r | _ -> diag (Some n) "not a register"

(* .safe (temporaries), .rathole (a struct thrown away), .ret (where a
 * struct is returned): made again for each file *)
let nodsafe : expr option ref = ref None
let nodrat : expr option ref = ref None
let nodret : expr option ref = ref None

(*****************************************************************************)
(* Registers (txt.c's regalloc...) *)
(*****************************************************************************)

let regs = ref [||]
let resvreg = ref [||]
let lasti = ref 0
let cursafe = ref 0
let curarg = ref 0
let maxargsafe = ref 0

let regret (nn : expr) =
  let r = if typefd (et nn) then (bk ()).fregret + (bk ()).nreg else (bk ()).regret in
  !regs.(r) <- !regs.(r) + 1;
  nodreg nn r

let tmpreg () =
  let rec go i = if i >= (bk ()).nreg then diag None "out of fixed registers" else if !regs.(i) = 0 then i else go (i + 1) in
  go ((bk ()).regret + 1)

(* a register for a value of tn's type: o's if o is one of that kind,
 * else the next free, round robin from the last, as 5c: the listings
 * depend on it *)
let regalloc (tn : expr) (o : expr option) =
  let bk = bk () in
  let found i = !regs.(i) <- !regs.(i) + 1; incr lasti; if !lasti >= 5 then lasti := 0; nodreg tn i in
  let e = et tn in
  let search lo hi start ok =
    let rec go k j = if k >= hi - lo then None else (let j = if j >= hi then lo else j in if ok j then Some j else go (k + 1) (j + 1)) in
    go 0 start
  in
  if (m ()).typeword e then
    match o with
    | Some { e = Reg reg; _ } when reg >= 0 && reg < bk.nreg -> found reg
    | _ -> (
        match search (bk.regret + 1) bk.nreg (!lasti + bk.regret + 1) (fun j -> !regs.(j) = 0 && !resvreg.(j) = 0) with
        | Some i -> found i
        | None -> diag (Some tn) "out of fixed registers")
  else if typefd e || typev e then
    match o with
    | Some { e = Reg reg; _ } when reg >= bk.nreg && reg < bk.nreg + bk.nfreg -> found reg
    | _ -> (
        let start = if bk.float_from_last then !lasti + bk.nreg else bk.nreg in
        match search bk.nreg (bk.nreg + bk.nfreg) start (fun j -> !regs.(j) = 0) with
        | Some i -> found i
        | None -> diag (Some tn) "out of float registers")
  else diag (Some tn) "unknown type in regalloc: %s" (show_type (Some tn.t))

let regialloc (tn : expr) o = regalloc { tn with t = ty Tind } o

let regfree (n : expr) =
  match n.e with
  | (Reg r | Indreg (r, _)) when r >= 0 && r < Array.length !regs && !regs.(r) > 0 -> !regs.(r) <- !regs.(r) - 1
  | _ -> ignore (diag (Some n) "error in regfree")

(* a temporary on the stack, below the locals *)
let regsalloc (nn : expr) =
  cursafe := Declare.align !cursafe nn.t Aaut3;
  maxargsafe := Declare.maxround !maxargsafe (!cursafe + !curarg);
  let n = Option.get !nodsafe in
  let e = match n.e with Name (s, c, _) -> Name (s, c, - (!Declare.stkoff + !cursafe)) | e -> e in
  { n with e; t = nn.t; line = nn.line }

(* an argument's place, made by f at its offset, the next one's after *)
let argument (nn : expr) f =
  curarg := Declare.align !curarg nn.t Aarg1;
  let n = f () in
  curarg := Declare.align !curarg nn.t Aarg2;
  maxargsafe := Declare.maxround !maxargsafe (!cursafe + !curarg);
  n

(* the first argument, in a register *)
let regaalloc1 (nn : expr) = argument nn (fun () -> let r = (bk ()).regret in !regs.(r) <- !regs.(r) + 1; nodreg nn r)

(* the others, above the return address *)
let regaalloc (nn : expr) =
  argument nn (fun () -> { nn with e = Indreg ((bk ()).regsp, !curarg + (bk ()).word); complex = 0; addable = Aconst })

(* the register n as an indirection, at off, of nn's type *)
let regind (n : expr) (nn : expr) off =
  match n.e with
  | Reg r -> { n with e = Indreg (r, off); t = nn.t }
  | _ -> diag (Some n) "regind not OREGISTER"

(* .rathole's size *)
let nrathole = ref 0

(* a file's start, after Emit's *)
let init () =
  nrathole := 0; lasti := 0;
  let bk = bk () in
  regs := Array.make (bk.nreg + bk.nfreg) 0;
  List.iter (fun r -> !regs.(r) <- 1) bk.reserved;
  resvreg := Array.copy !regs;
  nodsafe := Some (Check.complex (name_of (lookup ".safe") (ty Tint) Cauto 0));
  let t = typ Tarray (Some (ty Tchar)) in
  let s = lookup ".rathole" in
  s.sclass <- Cglobl; s.typ <- Some t;
  nodrat := Some { (Check.complex (name_of s (ty Tind) Cglobl 0)) with t };
  nodret := Some (Check.complex (mk (Unary (Ind, name_of (lookup ".ret") (ty Tind) Cparam 0))))

(* a file's end, before Emit's: .rathole's size *)
let gclean () = (Option.get (lookup ".rathole").typ).width <- !nrathole
