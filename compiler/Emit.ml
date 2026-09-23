(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Emit.mli *)

open Tree
module A = Ix_asm.Asm

(*****************************************************************************)
(* The machine, as the code generator sees it *)
(*****************************************************************************)

(* the registers are numbered as 5c's: the integer ones, then the
 * floating ones from nreg *)
type backend = {
  arch : A.arch;
  nreg : int;
  nfreg : int;
  regret : int;                       (* the result, and the first argument *)
  fregret : int;
  regsp : int;
  reserved : int list;                (* never allocated: SB, SP, the linker's temporary... *)
  regtmp : int;                       (* regnode's: a register only for its type *)
  word : int;                         (* an argument's slot above the return address *)
  float_from_last : bool;             (* the float registers rotate as the integer ones (7c) *)
  gmove : node -> node -> unit;
  gmover : node -> node -> unit;
  gopcode : op -> bool -> node option -> node option -> node option -> unit;
}

let be : backend option ref = ref None
let bk () = Option.get !be

(*****************************************************************************)
(* The instructions (5c's Prog) *)
(*****************************************************************************)

(* from, reg and to are 5c's: the listing prints them in this order *)
type prog = {
  mutable as_ : string;
  mutable cond : string list;         (* .LS, .U, .W: the suffixes *)
  mutable from : A.operand option;
  mutable reg : int option;           (* a second source register (F if from is) *)
  mutable to_ : A.operand option;     (* Target is a pc until the end *)
  mutable pseudo : [ `No | `Text of int | `Data of int | `Globl ];   (* TEXT's flag, DATA's width *)
  ppc : int;                          (* the next one's, for DATA and GLOBL *)
}

let progs : prog list ref = ref []    (* the last first *)
let pc = ref 0
let p () = List.hd !progs

let nextpc () =
  let q = { as_ = "GOK"; cond = []; from = None; reg = None; to_ = None; pseudo = `No; ppc = !pc } in
  progs := q :: !progs;
  incr pc;
  q

(*****************************************************************************)
(* Operands (txt.c's naddr) *)
(*****************************************************************************)

let name_of (s : sym) = { A.sym = s.name; static = s.sclass = Cstatic }

let sx32 v = Int64.of_int32 (Int64.to_int32 v)

let rec naddr (n : node) : A.operand =
  let m base name off = { A.base; name; off = sx32 (Int64.of_int off); index = None } in
  match n.op with
  | OREGISTER -> if n.reg >= (bk ()).nreg then A.FReg (n.reg - (bk ()).nreg) else A.Reg n.reg
  | OIND -> (
      match naddr (Tree.l n) with
      | A.Reg r -> A.Mem (m (A.R r) None 0)
      | A.Addr a -> A.Mem a
      | _ -> diag (Some n) "bad in naddr: %s" (opname n.op))
  | OINDREG -> A.Mem (m (A.R n.reg) None n.xoffset)
  | ONAME ->
      let s = sym n in
      let base =
        match n.nclass with
        | Cstatic | Cextern | Cglobl -> A.SB
        | Cauto -> A.SP
        | Cparam -> A.FP
        | _ -> diag (Some n) "bad in naddr: %s" (opname n.op)
      in
      A.Mem (m base (Some { A.sym = s.name; static = n.nclass = Cstatic }) n.xoffset)
  | OCONST -> if typefd (et n) then A.Fimm n.fconst else A.Imm (sx32 n.vconst)
  | OADDR -> (match naddr (Tree.l n) with A.Mem a -> A.Addr a | _ -> diag (Some n) "bad in naddr: %s" (opname n.op))
  | OADD ->
      let c, x = if (Tree.l n).op = OCONST then Tree.l n, Tree.r n else Tree.r n, Tree.l n in
      let v = match naddr c with A.Imm v -> v | _ -> 0L in
      (match naddr x with
       | A.Mem a -> A.Mem { a with off = sx32 (Int64.add a.off v) }
       | A.Addr a -> A.Addr { a with off = sx32 (Int64.add a.off v) }
       | A.Imm w -> A.Imm (sx32 (Int64.add w v))
       | o -> o)
  | _ -> diag (Some n) "bad in naddr: %s" (opname n.op)

let naddr_opt = Option.map naddr

let add_off (o : A.operand option) d =
  match o with
  | Some (A.Mem a) -> Some (A.Mem { a with off = sx32 (Int64.add a.off (Int64.of_int d)) })
  | Some (A.Addr a) -> Some (A.Addr { a with off = sx32 (Int64.add a.off (Int64.of_int d)) })
  | Some (A.Imm v) -> Some (A.Imm (sx32 (Int64.add v (Int64.of_int d))))
  | o -> o

(* the register of a node, as a second source (txt.c's raddr) *)
let raddr (n : node option) (q : prog) =
  match Option.map naddr n with
  | Some (A.Reg r) | Some (A.FReg r) -> q.reg <- Some r
  | _ -> ignore (diag n "bad in raddr")

let gins a (f : node option) (t : node option) =
  let q = nextpc () in
  q.as_ <- a;
  q.from <- naddr_opt f;
  q.to_ <- naddr_opt t;
  q

let gbranch (o : op) =
  let q = nextpc () in
  q.as_ <- (match o with ORETURN -> "RET" | OGOTO -> "B" | _ -> diag None "bad in gbranch");
  q

let patch (q : prog) target = q.to_ <- Some (A.Target target)

let gpseudo a (s : sym) (n : node) =
  let q = nextpc () in
  q.as_ <- a;
  q.from <- Some (A.Mem { A.base = A.SB; name = Some (name_of s); off = 0L; index = None });
  q.to_ <- Some (naddr n);
  if a = "DATA" || a = "GLOBL" then decr pc;
  q

(*****************************************************************************)
(* Nodes the generator makes (txt.c's ginit) *)
(*****************************************************************************)

let znode () = node OXXX None None

let nodconst v = let n = node OCONST None None in n.ntype <- Some (ty Tlong); n.addable <- 20; n.vconst <- v; n
let nodfconst d = let n = node OCONST None None in n.ntype <- Some (ty Tdouble); n.addable <- 20; n.fconst <- d; n

let nodreg (nn : node) r =
  let n = node OREGISTER None None in
  n.nclass <- Cexreg; n.reg <- r; n.addable <- 11; n.ntype <- nn.ntype; n.lineno <- nn.lineno;
  n

let regnode () = let n = node OREGISTER None None in n.nclass <- Cexreg; n.reg <- (bk ()).regtmp; n.addable <- 11; n.ntype <- Some (ty Tlong); n

(* .safe (temporaries), .rathole (a struct thrown away), .ret (where a
 * struct is returned): made again for each file *)
let nodsafe : node option ref = ref None
let nodrat : node option ref = ref None
let nodret : node option ref = ref None

(*****************************************************************************)
(* Registers (txt.c's regalloc...) *)
(*****************************************************************************)

let regs = ref [||]
let resvreg = ref [||]
let lasti = ref 0
let cursafe = ref 0
let curarg = ref 0
let maxargsafe = ref 0

let regret (nn : node) =
  let r = if typefd (et nn) then (bk ()).fregret + (bk ()).nreg else (bk ()).regret in
  !regs.(r) <- !regs.(r) + 1;
  nodreg nn r

let tmpreg () =
  let rec go i = if i >= (bk ()).nreg then diag None "out of fixed registers" else if !regs.(i) = 0 then i else go (i + 1) in
  go ((bk ()).regret + 1)

(* round robin from the last, as 5c: the listings depend on it *)
let regalloc (tn : node) (o : node option) =
  let bk = bk () in
  let found i = !regs.(i) <- !regs.(i) + 1; incr lasti; if !lasti >= 5 then lasti := 0; nodreg tn i in
  let e = et tn in
  let search lo hi start ok =
    let rec go k j = if k >= hi - lo then None else (let j = if j >= hi then lo else j in if ok j then Some j else go (k + 1) (j + 1)) in
    go 0 start
  in
  if (m ()).typeword e then
    match o with
    | Some { op = OREGISTER; reg; _ } when reg >= 0 && reg < bk.nreg -> found reg
    | _ -> (
        match search (bk.regret + 1) bk.nreg (!lasti + bk.regret + 1) (fun j -> !regs.(j) = 0 && !resvreg.(j) = 0) with
        | Some i -> found i
        | None -> diag (Some tn) "out of fixed registers")
  else if typefd e || typev e then
    match o with
    | Some { op = OREGISTER; reg; _ } when reg >= bk.nreg && reg < bk.nreg + bk.nfreg -> found reg
    | _ -> (
        let start = if bk.float_from_last then !lasti + bk.nreg else bk.nreg in
        match search bk.nreg (bk.nreg + bk.nfreg) start (fun j -> !regs.(j) = 0) with
        | Some i -> found i
        | None -> diag (Some tn) "out of float registers")
  else diag (Some tn) "unknown type in regalloc: %s" (show_type tn.ntype)

let regialloc (tn : node) o = regalloc { tn with ntype = Some (ty Tind) } o

let regfree (n : node) =
  if (n.op <> OREGISTER && n.op <> OINDREG) || n.reg < 0 || n.reg >= Array.length !regs || !regs.(n.reg) <= 0 then
    ignore (diag (Some n) "error in regfree: %d" n.reg)
  else !regs.(n.reg) <- !regs.(n.reg) - 1

(* a temporary on the stack, below the locals *)
let regsalloc (nn : node) =
  cursafe := Declare.align !cursafe (t nn) Declare.aaut3;
  maxargsafe := Declare.maxround !maxargsafe (!cursafe + !curarg);
  let n = dup (Option.get !nodsafe) in
  n.xoffset <- - (!Declare.stkoff + !cursafe);
  n.ntype <- nn.ntype; n.netype <- et nn; n.lineno <- nn.lineno;
  n

(* the first argument, in a register *)
let regaalloc1 (nn : node) =
  let n = nodreg nn (bk ()).regret in
  !regs.((bk ()).regret) <- !regs.((bk ()).regret) + 1;
  curarg := Declare.align !curarg (t nn) Declare.aarg1;
  curarg := Declare.align !curarg (t nn) Declare.aarg2;
  maxargsafe := Declare.maxround !maxargsafe (!cursafe + !curarg);
  n

(* the others, above the return address *)
let regaalloc (nn : node) =
  curarg := Declare.align !curarg (t nn) Declare.aarg1;
  let n = dup nn in
  n.op <- OINDREG; n.reg <- (bk ()).regsp; n.xoffset <- !curarg + (bk ()).word; n.complex <- 0; n.addable <- 20;
  curarg := Declare.align !curarg (t nn) Declare.aarg2;
  maxargsafe := Declare.maxround !maxargsafe (!cursafe + !curarg);
  n

let regind (n : node) (nn : node) =
  if n.op <> OREGISTER then ignore (diag (Some n) "regind not OREGISTER");
  n.op <- OINDREG;
  n.ntype <- nn.ntype

(*****************************************************************************)
(* Data (swt.c's outstring, gextern) *)
(*****************************************************************************)

(* the strings, 8 bytes to a DATA; nstring is .string's size *)
let nstring = ref 0
let sbuf = Buffer.create 8
let nrathole = ref 0
let suppress = ref 0

let outstring (s : string) n =
  if !suppress > 0 then !nstring
  else begin
    let r = !nstring in
    for i = 0 to n - 1 do
      Buffer.add_char sbuf (if i < String.length s then s.[i] else '\000');
      incr nstring;
      if Buffer.length sbuf >= 8 then begin
        let q = gpseudo "DATA" (lookup ".string") (nodconst 0L) in
        q.from <- add_off q.from (!nstring - 8);
        q.pseudo <- `Data 8;
        q.to_ <- Some (A.Str (Buffer.contents sbuf));
        Buffer.clear sbuf
      end
    done;
    r
  end

let gextern (s : sym) (a : node) o w =
  let data v off w =
    let q = gpseudo "DATA" s v in
    q.from <- add_off q.from off;
    q.pseudo <- `Data w;
    (match q.to_ with Some (A.Mem m) -> q.to_ <- Some (A.Addr m) | _ -> ())
  in
  if a.op = OCONST && typev (et a) then begin
    (* little-endian: the low word first *)
    data (nodconst (sx32 a.vconst)) o 4;
    data (nodconst (sx32 (Int64.shift_right a.vconst 32))) (o + 4) 4
  end
  else data a o w

(*****************************************************************************)
(* The end of a file: GLOBLs, and the output *)
(*****************************************************************************)

let init () =
  progs := []; pc := 0; nstring := 0; Buffer.clear sbuf; nrathole := 0; suppress := 0; lasti := 0;
  let bk = bk () in
  regs := Array.make (bk.nreg + bk.nfreg) 0;
  List.iter (fun r -> !regs.(r) <- 1) bk.reserved;
  resvreg := Array.copy !regs;
  let s = lookup ".safe" in
  let n = node ONAME None None in
  n.nsym <- Some s; n.ntype <- Some (ty Tint); n.netype <- Tint; n.nclass <- Cauto;
  Check.complex (Some n);
  nodsafe := Some n;
  let t = typ Tarray (Some (ty Tchar)) in
  let s = lookup ".rathole" in
  s.sclass <- Cglobl; s.typ <- Some t;
  let n = node ONAME None None in
  n.nsym <- Some s; n.ntype <- Some (ty Tind); n.netype <- Tvoid; n.nclass <- Cglobl;
  Check.complex (Some n);
  n.ntype <- Some t;
  nodrat := Some n;
  let n = node ONAME None None in
  n.nsym <- Some (lookup ".ret"); n.ntype <- Some (ty Tind); n.netype <- Tind; n.nclass <- Cparam;
  let n = node OIND (Some n) None in
  Check.complex (Some n);
  nodret := Some n

(* the static data, in the symbols' hash order (txt.c's gclean) *)
let gclean () =
  while Buffer.length sbuf > 0 do ignore (outstring "" 1) done;
  (Option.get (lookup ".string").typ).width <- !nstring;
  (Option.get (lookup ".rathole").typ).width <- !nrathole;
  Array.iter (fun bucket ->
    List.iter (fun (s : sym) ->
      match s.typ with
      | Some t when t.width <> 0 && (s.sclass = Cglobl || s.sclass = Cstatic) && t != ty Tenum ->
          let q = gpseudo "GLOBL" s (nodconst (Int64.of_int t.width)) in
          q.pseudo <- `Globl
      | _ -> ()) bucket) hash

(* 5c's listing (list.c, as principia's 5c prints it) *)
let show_mem (a : A.mem) =
  match a.name, a.base with
  | Some n, A.SB -> Printf.sprintf "%s%s+%Ld(SB)" n.sym (if n.static then "<>" else "") a.off
  | Some n, A.SP -> Printf.sprintf "%s-%Ld(SP)" n.sym (Int64.neg a.off)
  | Some n, A.FP -> Printf.sprintf "%s+%Ld(FP)" n.sym a.off
  | _, A.R r -> Printf.sprintf "%Ld(R%d)" a.off r
  | _ -> "GOK"

let escape s =
  String.concat "" (List.map (fun c ->
    match c with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | ' ' | '%' -> String.make 1 c
    | '\000' -> "\\z" | '\\' -> "\\\\" | '"' -> "\\\"" | '\n' -> "\\n" | '\t' -> "\\t" | '\r' -> "\\r" | '\012' -> "\\f"
    | c -> let c = Char.code c in Printf.sprintf "\\%d%d%d" (c lsr 6) ((c lsr 3) land 7) (c land 7))
    (List.init (String.length s) (String.get s)))

(* %.17e as Plan 9's fmt prints it (fltfmt.c's xdtoa): the fewest digits
 * that read back as f, then zeros; not the exact decimal, as glibc *)
let e17 f =
  let neg = f < 0. in
  let f = Float.abs f in
  let digits, e =
    if f = 0. then "0", 0
    else begin
      let pows10 = Array.init 160 (fun i -> float_of_string ("1e" ^ string_of_int i)) in
      let rec pow10 n =
        if n < 0 then 1. /. pow10 (- n)
        else if n < 160 then pows10.(n)
        else (let rec go d n = let n = n - 159 in if n < 160 then d *. pows10.(n) else go (d *. pows10.(159)) n in go pows10.(159) n)
      in
      let e = ref (truncate (float_of_int (snd (Float.frexp f)) *. 0.301029995664)) in
      let g = ref (f *. pow10 (- !e)) in
      while !g < 1. do decr e; g := f *. pow10 (- !e) done;
      while !g >= 10. do incr e; g := f *. pow10 (- !e) done;
      let s = Bytes.make 17 '0' in
      for i = 0 to 16 do let d = truncate !g in Bytes.set s i (Char.chr (d + 48)); g := (!g -. float_of_int d) *. 10. done;
      let e = ref (!e - 16) in
      let value s e = float_of_string (Bytes.to_string s ^ "e" ^ string_of_int e) in
      let add1 s = let rec go i = if i < 0 then (Bytes.set s 0 '1'; true) else if Bytes.get s i < '9' then (Bytes.set s i (Char.chr (Char.code (Bytes.get s i) + 1)); false) else (Bytes.set s i '0'; go (i - 1)) in go 16 in
      let sub1 s =
        let rec go i =
          if i < 0 then false
          else
            let c = Char.code (Bytes.get s i) - 1 in
            if c >= 48 then (if c = 48 && i = 0 then (Bytes.set s i '9'; true) else (Bytes.set s i (Char.chr c); false))
            else (Bytes.set s i '9'; go (i - 1))
        in
        go 16
      in
      (* until it reads back as f *)
      (try
         for _ = 1 to 10 do
           let g = value s !e in
           if f > g then (if add1 s then decr e)
           else if f < g then (if sub1 s then incr e)
           else raise Exit
         done
       with Exit -> ());
      (* the last digits up to 9, then 9s to 0s, then down to 0, while it reads back *)
      (try for i = 16 downto 14 do let c = Bytes.get s i in if c <> '9' then (Bytes.set s i '9'; if value s !e <> f then (Bytes.set s i c; raise Exit)) done with Exit -> ());
      if Bytes.get s 16 = '9' then begin
        let t = Bytes.copy s and ee = ref !e in
        if add1 t then decr ee;
        if value t !ee = f then (Bytes.blit t 0 s 0 17; e := !ee)
      end;
      (try for i = 16 downto 14 do let c = Bytes.get s i in if c <> '0' then (Bytes.set s i '0'; if value s !e <> f then (Bytes.set s i c; raise Exit)) done with Exit -> ());
      let n = ref 17 in
      while !n > 1 && Bytes.get s (!n - 1) = '0' do incr e; decr n done;
      Bytes.sub_string s 0 !n, !e + !n - 1
    end
  in
  let d = digits ^ String.make (18 - String.length digits) '0' in
  Printf.sprintf "%s%c.%se%c%02d" (if neg then "-" else "") d.[0] (String.sub d 1 17) (if e < 0 then '-' else '+') (abs e)

let show_operand ppc (o : A.operand) =
  match o with
  | A.Reg r -> Printf.sprintf "R%d" r
  | A.FReg r -> Printf.sprintf "F%d" r
  | A.Imm v -> Printf.sprintf "$%Ld" v
  | A.Fimm f -> "$" ^ e17 f
  | A.Str s -> Printf.sprintf "$\"%s\"" (escape s)
  | A.Mem a -> show_mem a
  | A.Addr a -> "$" ^ show_mem a
  | A.Regs rs -> "[" ^ String.concat "," (List.map (Printf.sprintf "R%d") rs) ^ "]"
  | A.Target t -> Printf.sprintf "%d(PC)" (t - ppc)
  | _ -> "GOK"

let show_prog (q : prog) =
  let op = String.concat "" (q.as_ :: List.map (fun s -> "." ^ s) q.cond) in
  let o = function Some x -> show_operand q.ppc x | None -> "" in
  let s =
    match q.pseudo with
    | `Data w -> Printf.sprintf "\t%s\t%s/%d,%s" op (o q.from) w (o q.to_)
    | `Text flag -> Printf.sprintf "\t%s\t%s,%d,%s" op (o q.from) flag (o q.to_)
    | _ -> (
        match q.reg, q.from with
        | None, _ -> Printf.sprintf "\t%s\t%s,%s" op (o q.from) (o q.to_)
        | Some r, Some (A.FReg _) -> Printf.sprintf "\t%s\t%s,F%d,%s" op (o q.from) r (o q.to_)
        | Some r, _ -> Printf.sprintf "\t%s\t%s,R%d,%s" op (o q.from) r (o q.to_))
  in
  (* pconvtrim: no comma first, nor last *)
  let s = match String.index_from_opt s 1 '\t' with Some i when i + 1 < String.length s && s.[i + 1] = ',' -> String.sub s 0 (i + 1) ^ String.sub s (i + 2) (String.length s - i - 2) | _ -> s in
  if String.length s > 0 && s.[String.length s - 1] = ',' then String.sub s 0 (String.length s - 1) else s

(* claude: 5c prints END as an instruction, a tab after it *)
let listing () = String.concat "" (List.rev_map (fun q -> show_prog q ^ "\n") !progs) ^ "\tEND\t\n"

(* the object: what TinyAsm makes of the listing *)
let obj file : A.obj =
  let ps = Array.of_list (List.rev !progs) in
  let of_pc = Hashtbl.create 64 in
  Array.iteri (fun i q -> if q.ppc >= 0 && (match q.pseudo with `Data _ | `Globl -> false | _ -> true) then Hashtbl.replace of_pc q.ppc i) ps;
  let items = Array.map (fun q ->
    let operand = function A.Target t -> A.Target (Hashtbl.find of_pc t) | o -> o in
    let args = List.filter_map Fun.id [ q.from; Option.map (fun r -> match q.from with Some (A.FReg _) -> A.FReg r | _ -> A.Reg r) q.reg; q.to_ ] in
    let item =
      match q.pseudo, q.from, q.to_ with
      | `Text flag, Some (A.Mem { name = Some n; _ }), Some (A.Imm v) -> A.Text (n, flag, v)
      | `Globl, Some (A.Mem { name = Some n; _ }), Some (A.Imm v) -> A.Globl (n, 0, v)
      | `Data w, Some (A.Mem { name = Some n; off; _ }), Some v -> A.Data (n, off, w, v)
      | _ -> A.Ins { op = q.as_; suffixes = q.cond; args = List.map operand args }
    in
    item, 0) ps in
  { A.arch = (bk ()).arch; file; items }
