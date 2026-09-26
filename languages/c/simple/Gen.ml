(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Gen.mli *)

open Lower
module A = Ix_asm.Asm

(* what differs between the machines, but the mnemonics (below) *)
type mach = {
  sp : int;                 (* the machine's stack pointer *)
  word : int;               (* a register's bytes; the arguments start above the link *)
  nregs : int;              (* the stack's registers: R1.. and F1.. *)
  nfregs : int;
  tmp : int;                (* scratch *)
  ftmp : int;
  ret : string;
}

let arm64 = { sp = 31; word = 8; nregs = 15; nfregs = 15; tmp = 16; ftmp = 16; ret = "RETURN" }
let arm = { sp = 13; word = 4; nregs = 7; nfregs = 6; tmp = 8; ftmp = 7; ret = "RET" }
let a64 () = not (Emit.arm ())
let mach () = if a64 () then arm64 else arm

(*****************************************************************************)
(* The instructions, by machine *)
(*****************************************************************************)

let ins ?reg a from to_ =
  let q = Emit.nextpc () in
  q.as_ <- a; q.from <- from; q.reg <- reg; q.to_ <- to_;
  q

let i1 a x = ignore (ins a (Some x) None)
let i2 a x y = ignore (ins a (Some x) (Some y))
let r n = A.Reg n and f n = A.FReg n
let at base off = A.Mem { A.base = A.R base; name = None; off = Int64.of_int off; index = None }

let mov () = if a64 () then "MOV" else "MOVW"
let fmov () = if a64 () then "FMOVD" else "MOVD"

let load_op = function
  | I (1, s) -> if s then "MOVB" else "MOVBU"
  | I (2, s) -> if s then "MOVH" else "MOVHU"
  | I (4, s) -> if a64 () && not s then "MOVWU" else "MOVW"
  | I _ -> "MOV"
  | F 4 -> if a64 () then "FMOVS" else "MOVF"
  | F _ -> fmov ()

let store_op = function I (1, _) -> "MOVB" | I (2, _) -> "MOVH" | I (4, _) -> "MOVW" | t -> load_op t

(* a register's value made its type's: extended, as a load would *)
let extend t x =
  match t with
  | I (w, s) when w < (mach ()).word ->
      if a64 () then i2 ((if s then "SXT" else "UXT") ^ (match w with 1 -> "B" | 2 -> "H" | _ -> "W")) (r x) (r x)
      else i2 (load_op t) (r x) (r x)
  | _ -> ()

let int_op (o : Tree.binop) =
  match o, a64 () with
  | Add, _ -> "ADD" | Sub, _ -> "SUB" | And, _ -> "AND" | Or, _ -> "ORR" | Xor, _ -> "EOR"
  | (Mul | Lmul), true -> "MUL" | Div, true -> "SDIV" | Ldiv, true -> "UDIV" | Mod, true -> "REM" | Lmod, true -> "UREM"
  | Ashl, true -> "LSL" | Ashr, true -> "ASR" | Lshr, true -> "LSR"
  | Mul, false -> "MUL" | Lmul, false -> "MULU" | Div, false -> "DIV" | Ldiv, false -> "DIVU" | Mod, false -> "MOD"
  | Lmod, false -> "MODU" | Ashl, false -> "SLL" | Ashr, false -> "SRA" | Lshr, false -> "SRL"
  | o, _ -> Tree.diag None "simple: no instruction for %s" (Tree.binop_name o)

let prec = function F 4 -> if a64 () then "S" else "F" | _ -> "D"
let float_op (o : Tree.binop) t =
  let o = match o with Add -> "ADD" | Sub -> "SUB" | Mul -> "MUL" | Div -> "DIV" | o -> Tree.diag None "simple: no float %s" (Tree.binop_name o) in
  (if a64 () then "F" else "") ^ o ^ prec t

(* the branch taken when a o b, after a comparison of a with b; a float's
 * false when unordered *)
let cond (o : Tree.binop) ~fl =
  let c : A.cond =
    match o with
    | Eq -> EQ | Ne -> NE | Lt -> if fl then MI else LT | Le -> if fl then LS else LE | Gt -> GT | Ge -> GE
    | Lo -> LO | Ls -> LS | Hi -> HI | Hs -> HS
    | _ -> Tree.diag None "simple: not a relation"
  in
  "B" ^ A.string_of_cond c

(*****************************************************************************)
(* A function *)
(*****************************************************************************)

(* the stack: a slot's kind, the top first; slot i is Ri, or Fi *)
type kind = K_int | K_float

let kind = function I _ -> K_int | F _ -> K_float

let func (fn : func) =
  let m = mach () in
  let stack = ref [] and dead = ref false and spills = ref 0 in
  let at_label = Hashtbl.create 16 and pcs = Hashtbl.create 16 and jumps = ref [] in
  let depth () = List.length !stack in
  let push k =
    stack := k :: !stack;
    let d = depth () in
    if d > (if k = K_int then m.nregs else m.nfregs) then Tree.diag None "%s: an expression too deep" fn.name.name;
    d
  in
  let pop () = let d = depth () in stack := List.tl !stack; d in
  let reg k d = if k = K_int then r d else f d in
  let move k x y = if x <> y then i2 (if k = K_int then mov () else fmov ()) (reg k x) (reg k y) in
  (* the top's register, its kind now t's *)
  let retype t = let d = pop () in ignore (push (kind t)); d in
  let jump a l = Hashtbl.replace at_label l !stack; jumps := (ins a None None, l) :: !jumps in
  (* the stack's slots, around a call, below the locals *)
  let slot i = A.Mem { A.base = A.SP; name = Some { A.sym = ".safe"; static = false }; off = Int64.of_int (- (fn.locals + (8 * i))); index = None } in
  let spill f = List.iteri (fun j k -> let i = depth () - j in spills := max !spills i; f k i) !stack in
  (* n bytes from 0(src) to off(dst), by words when they are all words *)
  let copy src dst off n =
    let w = if a64 () && n mod 8 = 0 then 8 else if n mod 4 = 0 then 4 else 1 in
    let t = I (w, false) in
    for k = 0 to (n / w) - 1 do
      i2 (load_op t) (at src (k * w)) (r m.tmp);
      i2 (store_op t) (r m.tmp) (at dst (off + (k * w)))
    done
  in
  let compare t =
    let b = pop () in
    let a = pop () in
    (match t with
     | I _ -> ignore (ins "CMP" ~reg:a (Some (r b)) None)
     | F _ -> ignore (ins ((if a64 () then "FCMP" else "CMP") ^ prec t) ~reg:a (Some (f b)) None));
    a
  in
  let ir i =
    match i with
    | Label l ->
        (* the stack the jumps to it had; none after dead code: a
         * statement's label, jumped to later, where the stack is empty *)
        (match Hashtbl.find_opt at_label l with Some s -> stack := s | None -> if !dead then stack := []);
        dead := false;
        Hashtbl.replace pcs l !Emit.pc
    | _ when !dead -> ()
    | Int (v, t) -> let d = push (kind t) in i2 (mov ()) (A.Imm (if a64 () then v else Emit.sx32 v)) (r d)
    | Flt (x, t) -> let d = push K_float in i2 (load_op t) (A.Fimm x) (f d)
    | Lea mm -> let d = push K_int in i2 (mov ()) (A.Addr mm) (r d)
    | Load t -> let d = retype t in i2 (load_op t) (at d 0) (reg (kind t) d)
    | Store t ->
        let v = pop () in
        let a = retype t in
        i2 (store_op t) (reg (kind t) v) (at a 0);
        move (kind t) v a
    | Copy n -> let s = pop () in copy s (depth ()) 0 n
    | Op (o, t) when Tree.is_rel o ->
        let a = compare t in
        ignore (push K_int);
        i2 (mov ()) (A.Imm 1L) (r a);
        let q = ins (cond o ~fl:(kind t = K_float)) None None in
        i2 (mov ()) (A.Imm 0L) (r a);
        Emit.patch q !Emit.pc
    | Op (o, (I _ as t)) ->
        let b = pop () in
        let a = depth () in
        ignore (ins (int_op o) ~reg:a (Some (r b)) (Some (r a)));
        extend t a
    | Op (o, t) -> let b = pop () in let a = depth () in ignore (ins (float_op o t) ~reg:a (Some (f b)) (Some (f a)))
    | Neg (I _ as t) -> let a = depth () in i2 "NEG" (r a) (r a); extend t a
    | Neg t -> let a = depth () in i2 ("FNEG" ^ prec t) (f a) (f a)
    | Com t -> let a = depth () in i2 "MVN" (r a) (r a); extend t a
    | Cvt (x, y) when x = y -> ()
    | Cvt (I _, (I _ as y)) -> extend y (depth ())
    | Cvt (I (_, s), (F _ as y)) ->
        let d = retype y in
        if a64 () then i2 ((if s then "SCVTF" else "UCVTF") ^ prec y) (r d) (f d)
        else begin
          i2 "MOVWD" (r d) (f d);
          (* the top bit apart: vfp's conversion is signed *)
          if not s then begin
            ignore (ins "CMP" ~reg:d (Some (A.Imm 0L)) None);
            let q = ins "BGE" None None in
            i2 "MOVD" (A.Fimm 4294967296.) (f m.ftmp);
            ignore (ins "ADDD" ~reg:d (Some (f m.ftmp)) (Some (f d)));
            Emit.patch q !Emit.pc
          end;
          if y = F 4 then i2 "MOVDF" (f d) (f d)
        end
    | Cvt ((F _ as x), (I (_, s) as y)) ->
        let d = retype y in
        if a64 () then i2 ("FCVTZ" ^ (if s then "S" else "U") ^ prec x) (f d) (r d)
        else i2 (if x = F 4 then "MOVFW" else "MOVDW") (f d) (r d);
        extend y d
    | Cvt (x, _) ->
        let d = depth () in
        i2 (match a64 (), x with true, F 4 -> "FCVTSD" | true, _ -> "FCVTDS" | false, F 4 -> "MOVFD" | false, _ -> "MOVDF") (f d) (f d)
    | Dup -> let k = List.hd !stack in let a = depth () in move k a (push k)
    | Drop -> ignore (pop ())
    | Swap ->
        let kb = List.hd !stack and ka = List.nth !stack 1 and b = depth () in
        let a = b - 1 in
        if ka = kb then (move ka a (if ka = K_int then m.tmp else m.ftmp); move kb b a; move ka (if ka = K_int then m.tmp else m.ftmp) b)
        else (move kb b a; move ka a b);
        stack := ka :: kb :: List.tl (List.tl !stack)
    | Over -> let k = List.nth !stack 1 and a = depth () - 1 in move k a (push k)
    | Arg (o, t) -> let v = pop () in i2 (store_op t) (reg (kind t) v) (at m.sp (m.word + o))
    | ArgBlock (o, n) -> let s = pop () in copy s m.sp (m.word + o) n
    | Call (target, r0, rt) ->
        let fn = match target with Direct mm -> A.Mem mm | Indirect -> at (pop ()) 0 in
        spill (fun k i -> i2 (if k = K_int then mov () else fmov ()) (reg k i) (slot i));
        Option.iter (fun t -> i2 (load_op t) (at m.sp m.word) (r 0)) r0;
        i1 "BL" fn;
        spill (fun k i -> i2 (if k = K_int then mov () else fmov ()) (slot i) (reg k i));
        Option.iter (fun t -> let d = push (kind t) in move (kind t) 0 d; if kind t = K_int then extend t d) rt
    | Jmp l -> jump "B" l; dead := true
    | Jz l | Jnz l ->
        let a = pop () in
        (* not CBZ: the linker's flow inverts a Bcc, as 7l's *)
        ignore (ins "CMP" ~reg:a (Some (A.Imm 0L)) None);
        jump (match i with Jz _ -> "BEQ" | _ -> "BNE") l
    | Ret t ->
        Option.iter (fun t -> let v = pop () in move (kind t) v 0) t;
        ignore (ins m.ret None None);
        dead := true
  in
  let text = Emit.gpseudo "TEXT" fn.name (Emit.nodconst 0L) in
  text.pseudo <- `Text (if !Pre.profile then 0 else 1);
  Option.iter (fun (mm, t) -> i2 (store_op t) (r 0) (A.Mem mm)) fn.r0;
  List.iter ir fn.code;
  List.iter (fun (q, l) -> Emit.patch q (Hashtbl.find pcs l)) !jumps;
  let frame = fn.locals + (8 * !spills) + fn.args in
  text.to_ <- Some (A.Imm (Int64.of_int (Declare.round frame (if a64 () then 8 else 4))))

let codgen (fn : Tree.sym) (body : Tree.stmt) = func (Lower.func fn body)
