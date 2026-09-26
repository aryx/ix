(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Lower.mli *)

open Tree
module A = Ix_asm.Asm

type ty = I of int * bool | F of int

type target = Direct of A.mem | Indirect

type ir =
  | Int of int64 * ty
  | Flt of float * ty
  | Lea of A.mem
  | Load of ty
  | Store of ty
  | Copy of int
  | Op of binop * ty
  | Neg of ty
  | Com of ty
  | Cvt of ty * ty
  | Dup | Drop | Swap | Over
  | Arg of int * ty
  | ArgBlock of int * int
  | Call of target * ty option * ty option
  | Label of int | Jmp of int | Jz of int | Jnz of int
  | Ret of ty option

type func = { name : Tree.sym; locals : int; args : int; r0 : (A.mem * ty) option; code : ir list }

(*****************************************************************************)
(* Types and places *)
(*****************************************************************************)

(* a structure's, a union's (and on arm a vlong's, 5c's structure) value
 * is its address *)
let block (t : typ) = typesu t.etype || (typev t.etype && ewidth Tind = 4)

let ty_of (t : typ) =
  match t.etype with
  | Tfloat | Tdouble -> F (ewidth t.etype)
  | e -> I (ewidth e, not (typeu e))

let mem_of (n : expr) = match Emit.naddr n with A.Mem m -> m | _ -> diag (Some n) "no place"

(* where the machine can't (arm), a vlong's operations as calls to
 * libc, bottom up: the hook the front end runs after its passes *)
let rec calls64 (n : expr) : expr =
  if (m ()).machcap None then n
  else begin
    let e =
      match n.e with
      | Unary (o, a) -> Unary (o, calls64 a)
      | Binary (o, a, b) -> let a = calls64 a in Binary (o, a, calls64 b)
      | Assign (o, a, b) -> let a = calls64 a in Assign (o, a, calls64 b)
      | Cond (c, a, b) -> let c = calls64 c in let a = calls64 a in Cond (c, a, calls64 b)
      | Call (f, args) -> let f = calls64 f in Call (f, map_lr calls64 args)
      | Dot (a, o) -> Dot (calls64 a, o)
      | e -> e
    in
    let n = { n with e } in
    match n.e with Name _ | Const _ | Fconst _ | Dot _ -> n | _ -> Option.value (Com64.com64 n) ~default:n
  end

(*****************************************************************************)
(* A function's state *)
(*****************************************************************************)

let code : ir list ref = ref []           (* the last first *)
let emit i = code := i :: !code
let labels = ref 0
let label () = incr labels; !labels

(* the temporaries, below the autos, freed after each statement but
 * the switches' values (below base) *)
let temps = ref 0 and base = ref 0 and maxtemps = ref 0 and maxargs = ref 0

let temp (t : typ) =
  temps := Declare.round (!temps + t.width) 8;
  maxtemps := max !maxtemps !temps;
  { A.base = A.SP; name = Some { A.sym = ".safe"; static = false }; off = Int64.of_int (- (!Declare.stkoff + !temps)); index = None }

(* a user's label, by its record *)
let ulabels : (label * int) list ref = ref []
let ulabel (l : label) = match List.assq_opt l !ulabels with Some k -> k | None -> let k = label () in ulabels := (l, k) :: !ulabels; k

let rec has_call (n : expr) =
  match n.e with
  | Call _ -> true
  | Unary (_, a) | Dot (a, _) -> has_call a
  | Binary (_, a, b) | Assign (_, a, b) -> has_call a || has_call b
  | Cond (c, a, b) -> has_call c || has_call a || has_call b
  | _ -> false

(* the stack slots n needs (Ershov's number, Sethi-Ullman's count) *)
let rec need (n : expr) =
  match n.e with
  | Binary (_, a, b) | Assign (_, a, b) -> let x = need a and y = need b in if x = y then x + 1 else max x y
  | Unary (_, a) | Dot (a, _) -> need a
  | Cond (c, a, b) -> max (need c) (max (need a) (need b))
  | _ -> 1

(*****************************************************************************)
(* Expressions *)
(*****************************************************************************)

(* the value of n pushed: a scalar, or a block's address; nothing if void *)
let rec value (n : expr) =
  let t = ty_of n.t in
  match n.e with
  | Const v when block n.t ->
      (* arm's vlong: its two words in a temporary *)
      let m = temp n.t in
      List.iter (fun (o, w) -> emit (Lea { m with off = Int64.add m.off o }); emit (Int (w, I (4, true))); emit (Store (I (4, true))); emit Drop)
        [ 0L, Emit.sx32 v; 4L, Emit.sx32 (Int64.shift_right v 32) ];
      emit (Lea m)
  | Const v -> emit (Int (v, t))
  | Fconst f -> emit (Flt (f, t))
  | Name _ | Unary (Ind, _) | Dot _ -> addr n; if not (block n.t) then emit (Load t)
  | Unary (Addr, l) -> addr l
  | Unary (Neg, l) -> value l; emit (Neg t)
  | Unary (Com, l) -> value l; emit (Com t)
  | Unary (Cast, l) ->
      value l;
      if n.t.etype = Tvoid then drop l
      else if not (block n.t) && not (block l.t) then emit (Cvt (ty_of l.t, t))
  | Unary (((Preinc | Predec | Postinc | Postdec) as o), l) ->
      let v = if et l = Tind then (link l.t).width else 1 in
      let one = match t with F _ -> Flt (1., t) | I _ -> Int (Int64.of_int v, t) in
      let op = if o = Preinc || o = Postinc then Add else Sub in
      addr l;
      emit Dup;
      emit (Load t);
      if o = Postinc || o = Postdec then (emit Swap; emit Over; emit one; emit (Op (op, t)); emit (Store t); emit Drop)
      else (emit one; emit (Op (op, t)); emit (Store t))
  | Unary (Not, _) | Binary ((Andand | Oror), _, _) ->
      let f = label () and out = label () in
      branch n false f;
      emit (Int (1L, t)); emit (Jmp out);
      emit (Label f); emit (Int (0L, t));
      emit (Label out)
  | Binary (Comma, a, b) -> effect a; value b
  | Binary (o, l, r) -> operands l r; emit (Op (o, if is_rel o then ty_of l.t else t))
  | Assign (None, l, r) ->
      (* a call's value first: nothing live across it, so that x =
       * setjmp(b) finds x's address again after a longjmp *)
      if has_call r then (value r; addr l; emit Swap) else (addr l; value r);
      emit (if block n.t then Copy n.t.width else Store t)
  | Assign (Some o, l, r) ->
      (* in n's type, stored in l's *)
      let tl = ty_of l.t in
      addr l;
      emit Dup;
      emit (Load tl);
      emit (Cvt (tl, t));
      value r;
      emit (Op (o, t));
      emit (Cvt (t, tl));
      emit (Store tl);
      emit (Cvt (tl, t))
  | Cond (c, a, b) ->
      let other = label () and out = label () in
      branch c false other;
      value a; emit (Jmp out);
      emit (Label other); value b;
      emit (Label out)
  | Call (f, args) -> call n f args
  | _ -> ignore (diag (Some n) "simple: unknown expression")

(* the deeper side first, so that the stack holds a deep expression; a
 * call's side keeps C's order, left to right *)
and operands (l : expr) (r : expr) =
  if need r > need l && not (has_call l || has_call r) then (value r; value l; emit Swap) else (value l; value r)

and drop (n : expr) = if n.t.etype <> Tvoid then emit Drop

and effect (n : expr) = value n; drop n

(* the address of an l-value, or of a block *)
and addr (n : expr) =
  match n.e with
  | Name _ -> emit (Lea (mem_of n))
  | Unary (Ind, p) -> value p
  | Dot (l, o) -> value l; emit (Int (Int64.of_int o, ty_of (ty Tind))); emit (Op (Add, ty_of (ty Tind)))
  | Binary (Comma, a, b) -> effect a; addr b
  | _ when block n.t -> value n
  | _ -> ignore (diag (Some n) "simple: not an l-value")

(* a jump to l when n's truth is tr *)
and branch (n : expr) tr l =
  match n.e with
  | Const v -> if (v <> 0L) = tr then emit (Jmp l)
  | Unary (Not, a) -> branch a (not tr) l
  | Binary (Comma, a, b) -> effect a; branch b tr l
  | Binary (((Andand | Oror) as o), a, b) ->
      (* a && b false, a || b true: either side says so *)
      if (o = Andand) <> tr then (branch a tr l; branch b tr l)
      else (let skip = label () in branch a (not tr) skip; branch b tr l; emit (Label skip))
  | _ ->
      value (Com64.bool64 n);
      (match ty_of n.t with F _ as t -> emit (Flt (0., t)); emit (Op (Ne, t)) | I _ -> ());
      emit (if tr then Jnz l else Jz l)

(* the arguments with calls first, to temporaries; then each at its
 * offset, the first also in R0 if it is a word; a block's result in a
 * temporary whose address is the hidden first argument *)
and call (n : expr) (f : expr) args =
  let res = if block n.t then Some (temp n.t) else None in
  let early (a : expr) =
    if not (has_call a) then `Now a
    else begin
      let m = temp a.t in
      emit (Lea m); value a;
      emit (if block a.t then Copy a.t.width else Store (ty_of a.t));
      emit Drop;
      `Temp (m, a.t)
    end
  in
  let args = List.map early args in
  let f = match f.e with Name _ -> `Name f | Unary (Ind, p) -> early p | _ -> diag (Some f) "simple: a call of what" in
  let off = ref 0 and r0 = ref None in
  let place (t : typ) push =
    off := Declare.align !off t Aarg1;
    let o = !off in
    push ();
    if block t then emit (ArgBlock (o, t.width)) else emit (Arg (o, ty_of t));
    if o = 0 && (m ()).typeword t.etype then r0 := Some (ty_of t);
    off := Declare.align !off t Aarg2
  in
  Option.iter (fun m -> place (ty Tind) (fun () -> emit (Lea m))) res;
  List.iter (function
    | `Now (a : expr) -> place a.t (fun () -> value a)
    | `Temp (m, t) -> place t (fun () -> emit (Lea m); if not (block t) then emit (Load (ty_of t)))) args;
  maxargs := max !maxargs !off;
  let target =
    match f with
    | `Name f -> Direct (mem_of f)
    | `Now p -> value p; Indirect
    | `Temp (m, t) -> emit (Lea m); emit (Load (ty_of t)); Indirect
  in
  let rt = if n.t.etype = Tvoid || block n.t then None else Some (ty_of n.t) in
  emit (Call (target, !r0, rt));
  Option.iter (fun m -> emit (Lea m)) res

(*****************************************************************************)
(* Statements *)
(*****************************************************************************)

(* where break and continue go; a switch's cases, the last first *)
type targets = { brk : int option; cont : int option; cases : (int64 option * int) list ref option }

let rec stmt (k : targets) (s : stmt) =
  let jump = function Some l -> emit (Jmp l) | None -> ignore (diag None "break or continue outside a loop") in
  let expr f (n : expr) = let n = Check.complex n in temps := !base; f n in
  match s with
  | Expr n -> expr effect n
  | Block l -> List.iter (stmt k) l
  | If (c, a, b) ->
      let other = label () in
      expr (fun c -> branch c false other) c;
      stmt k a;
      (match b with
       | Some b -> let out = label () in emit (Jmp out); emit (Label other); stmt k b; emit (Label out)
       | None -> emit (Label other))
  | While (c, body) ->
      let top = label () and out = label () in
      emit (Label top);
      expr (fun c -> branch c false out) c;
      stmt { k with brk = Some out; cont = Some top } body;
      emit (Jmp top); emit (Label out)
  | Dowhile (body, c) ->
      let top = label () and cont = label () and out = label () in
      emit (Label top);
      stmt { k with brk = Some out; cont = Some cont } body;
      emit (Label cont);
      expr (fun c -> branch c true top) c;
      emit (Label out)
  | For (init, c, step, body) ->
      stmt k init;
      let top = label () and cont = label () and out = label () in
      emit (Label top);
      Option.iter (expr (fun c -> branch c false out)) c;
      stmt { k with brk = Some out; cont = Some cont } body;
      emit (Label cont);
      stmt k step;
      emit (Jmp top); emit (Label out)
  | Switch (x, body) ->
      (* the value in a temporary, the cases after the body *)
      let x = Check.complex x in
      temps := !base;
      if not ((m ()).typeswitch (et x)) then ignore (diag (Some x) "switch expression must be integer");
      if block x.t then ignore (diag (Some x) "64-bit switches on 32-bit machines are not in the subset");
      let t = if typev (et x) then ty Tvlong else ty Tlong in
      let v = temp t and tv = ty_of t in
      value x; emit (Cvt (ty_of x.t, tv)); emit (Lea v); emit Swap; emit (Store tv); emit Drop;
      let dispatch = label () and out = label () and cases = ref [] and base0 = !base in
      emit (Jmp dispatch);
      base := !temps;
      stmt { k with brk = Some out; cases = Some cases } body;
      base := base0;
      emit (Jmp out);
      emit (Label dispatch);
      let all = List.rev !cases in
      List.iter (fun (c, l) ->
        Option.iter (fun c -> emit (Lea v); emit (Load tv); emit (Int (convvtox c t.etype, tv)); emit (Op (Eq, tv)); emit (Jnz l)) c) all;
      emit (Jmp (match List.assoc_opt None all with Some l -> l | None -> out));
      emit (Label out)
  | Case c -> (
      match k.cases with
      | None -> ignore (diag None "case/default outside a switch")
      | Some cases ->
          let l = label () in
          let c = Option.map (fun c -> match Check.complex c with { e = Const v; _ } -> v | c -> diag (Some c) "case expression must be integer constant") c in
          cases := (c, l) :: !cases;
          emit (Label l))
  | Label l -> emit (Label (ulabel l))
  | Goto l -> if not l.defined then ignore (diag None "label undefined: %s" l.lsym.name) else emit (Jmp (ulabel l))
  | Break -> jump k.brk
  | Continue -> jump k.cont
  | Return (None, _) -> emit (Ret None)
  | Return (Some x, rt) ->
      let x = Check.complex ~ret:rt x in
      temps := !base;
      if (m ()).typecmplx rt.etype then begin
        (* through the address the caller gave *)
        emit (Lea (mem_of (name_of (lookup ".ret") (ty Tind) Cparam 0)));
        emit (Load (ty_of (ty Tind)));
        value x;
        emit (Copy rt.width); emit Drop; emit (Ret None)
      end
      else (value x; emit (Ret (Some (ty_of rt))))
  | Used _ | Set _ -> ()

let func (fn : sym) (body : stmt) =
  code := []; temps := 0; base := 0; maxtemps := 0; maxargs := 0; ulabels := [];
  let ret = link (Option.get !Declare.thisfn) in
  (* the first argument arrives in R0: a block's result's address, or
   * the first parameter if it is a word *)
  let r0 =
    if (m ()).typecmplx ret.etype then Some (mem_of (name_of (lookup ".ret") (ty Tind) Cparam 0), ty_of (ty Tind))
    else
      match !Declare.firstarg, !Declare.firstargtype with
      | Some s, Some ft when (m ()).typeword ft.etype -> Some (mem_of (name_of s ft Cparam (Declare.align 0 ft Aarg1)), ty_of ft)
      | _ -> None
  in
  stmt { brk = None; cont = None; cases = None } body;
  emit (Ret None);
  { name = fn; locals = !Declare.stkoff + !maxtemps; args = !maxargs; r0; code = List.rev !code }
