(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Tree.mli *)

(*****************************************************************************)
(* Types' kinds, and their sets *)
(*****************************************************************************)

(* a type's kind; Tdot is a prototype's ..., Told an old-style one's
 * parameters *)
type etype =
  | Txxx | Tchar | Tuchar | Tshort | Tushort | Tint | Tuint | Tlong | Tulong | Tvlong | Tuvlong | Tfloat | Tdouble
  | Tind | Tfunc | Tarray | Tvoid | Tstruct | Tunion | Tenum | Tdot | Told

let kinds = [ Txxx, "TXXX"; Tchar, "CHAR"; Tuchar, "UCHAR"; Tshort, "SHORT"; Tushort, "USHORT"; Tint, "INT";
  Tuint, "UINT"; Tlong, "LONG"; Tulong, "ULONG"; Tvlong, "VLONG"; Tuvlong, "UVLONG"; Tfloat, "FLOAT";
  Tdouble, "DOUBLE"; Tind, "IND"; Tfunc, "FUNC"; Tarray, "ARRAY"; Tvoid, "VOID"; Tstruct, "STRUCT";
  Tunion, "UNION"; Tenum, "ENUM"; Tdot, "DOT"; Told, "OLD" ]
let tname t = List.assoc t kinds

(* the sets are named by their members' initials, as sub.c's: typechlp
 * is char, short, long (of each sign) and pointer *)
let set l t = List.mem t l
let integers = [ Tchar; Tuchar; Tshort; Tushort; Tint; Tuint; Tlong; Tulong; Tvlong; Tuvlong ]
let chl = [ Tchar; Tuchar; Tshort; Tushort; Tint; Tuint; Tlong; Tulong ]
let typei = set integers
let typeu = set [ Tuchar; Tushort; Tuint; Tulong; Tuvlong; Tind ]
let typesuv = set [ Tvlong; Tuvlong; Tstruct; Tunion ]
let typeilp = set [ Tint; Tuint; Tlong; Tulong; Tind ]
let typechl = set chl
let typechlv = typei
let typechlvp = set (Tind :: integers)
let typechlp = set (Tind :: chl)
let typev = set [ Tvlong; Tuvlong ]
let typefd = set [ Tfloat; Tdouble ]
let typeaf = set [ Tfunc; Tarray ]
let typesu = set [ Tstruct; Tunion ]
let number t = typei t || typefd t

(* which operand types an operator takes, the left and the right (sub.c's
 * tasign, tadd... tables) *)
let tasign l r = number l && number r || (l = Tind || typesu l) && r = l
let tasadd l r = number l && number r || l = Tind && typei r
let tadd l r = number l && number r || typei l && r = Tind || l = Tind && typei r
let tsub l r = number l && number r || l = Tind && (typei r || r = Tind)
let tmul l r = number l && number r
let tand l r = typei l && (typei r || (l = Tint || l = Tuint) && typefd r)
let trel l r = number l && number r || l = Tind && r = Tind
let tcast l r =
  r = Tvoid && (number l || l = Tind || l = Tvoid || typesu l)
  || number l && number r || typei l && r = Tind || l = Tind && (typei r || r = Tind) || typesu l && r = l
(* whatever the left type *)
let tfunct _ r = r = Tfunc and tindir _ r = r = Tind and tdots _ r = typesu r
and tnot _ r = number r || r = Tind and targ _ r = number r || r = Tind || typesu r

(* an integer's signed kind, and its unsigned one *)
let signs = [ Tchar, Tuchar; Tshort, Tushort; Tint, Tuint; Tlong, Tulong; Tvlong, Tuvlong ]
let signed t = match List.find_opt (fun (_, u) -> u = t) signs with Some (s, _) -> s | None -> t

(* the usual arithmetic conversions: the type of l op r (sub.c's tab,
 * with its quirks: no promotion, double op float is float); the larger
 * integer, unsigned if either is *)
let arith_tab (l : etype) (r : etype) =
  let size t = match signed t with Tchar -> 1 | Tshort -> 2 | Tint -> 3 | Tlong -> 4 | _ -> 5 in
  if not ((number l || l = Tind) && (number r || r = Tind)) then Txxx
  else if l = Tind || r = Tind then Tind
  else if typefd r then r
  else if typefd l then l
  else
    let s = if size l >= size r then signed l else signed r in
    if typeu l || typeu r then List.assoc s signs else s

(* char and short to int, keeping the sign *)
let promote = function Tchar | Tshort -> Tint | Tuchar | Tushort -> Tuint | t -> t

(* storage classes, and qualifiers (GCONSTNT...) *)
type cls = Cxxx | Cauto | Cextern | Cglobl | Cstatic | Clocal | Ctypedef | Ctypestr | Cparam | Cselem | Clabel | Cexreg
let cname = function
  | Cxxx -> "CXXX" | Cauto -> "AUTO" | Cextern -> "EXTERN" | Cglobl -> "GLOBL" | Cstatic -> "STATIC" | Clocal -> "LOCAL"
  | Ctypedef -> "TYPEDEF" | Ctypestr -> "TYPESTR" | Cparam -> "PARAM" | Cselem -> "SELEM" | Clabel -> "LABEL" | Cexreg -> "EXREG"
let gconstnt = 1 and gvolatile = 2 and gincomplete = 4
let gnames = [| "GXXX"; "CONST"; "VOLATILE"; "CONST-VOLATILE" |]

(*****************************************************************************)
(* The tree *)
(*****************************************************************************)

type op =
  | OXXX | OADD | OADDR | OAND | OANDAND | OARRAY | OAS | OASI | OASADD | OASAND | OASASHL | OASASHR | OASDIV
  | OASHL | OASHR | OASLDIV | OASLMOD | OASLMUL | OASLSHR | OASMOD | OASMUL | OASOR | OASSUB | OASXOR | OBIT
  | OBREAK | OCASE | OCAST | OCOMMA | OCOND | OCONST | OCONTINUE | ODIV | ODOT | ODOTDOT | ODWHILE | OENUM
  | OEQ | OFOR | OFUNC | OGE | OGOTO | OGT | OHI | OHS | OIF | OIND | OINDREG | OINIT | OLABEL | OLDIV | OLE
  | OLIST | OLMOD | OLMUL | OLO | OLS | OLSHR | OLT | OMOD | OMUL | ONAME | ONE | ONOT | OOR | OOROR
  | OPOSTDEC | OPOSTINC | OPREDEC | OPREINC | OPROTO | OREGISTER | ORETURN | OSET | OSIGN | OSIZE | OSTRING
  | OLSTRING | OSTRUCT | OSUB | OSWITCH | OUNION | OUSED | OWHILE | OXOR | ONEG | OCOM | OPOS | OELEM
  | OTST | OINDEX | OFAS | OREGPAIR | OEXREG

let opnames = [ OXXX, "OXXX"; OADD, "ADD"; OADDR, "ADDR"; OAND, "AND"; OANDAND, "ANDAND"; OARRAY, "ARRAY"; OAS, "AS";
  OASI, "ASI"; OASADD, "ASADD"; OASAND, "ASAND"; OASASHL, "ASASHL"; OASASHR, "ASASHR"; OASDIV, "ASDIV";
  OASHL, "ASHL"; OASHR, "ASHR"; OASLDIV, "ASLDIV"; OASLMOD, "ASLMOD"; OASLMUL, "ASLMUL"; OASLSHR, "ASLSHR";
  OASMOD, "ASMOD"; OASMUL, "ASMUL"; OASOR, "ASOR"; OASSUB, "ASSUB"; OASXOR, "ASXOR"; OBIT, "BIT"; OBREAK, "BREAK";
  OCASE, "CASE"; OCAST, "CAST"; OCOMMA, "COMMA"; OCOND, "COND"; OCONST, "CONST"; OCONTINUE, "CONTINUE"; ODIV, "DIV";
  ODOT, "DOT"; ODOTDOT, "DOTDOT"; ODWHILE, "DWHILE"; OENUM, "ENUM"; OEQ, "EQ"; OFOR, "FOR"; OFUNC, "FUNC"; OGE, "GE";
  OGOTO, "GOTO"; OGT, "GT"; OHI, "HI"; OHS, "HS"; OIF, "IF"; OIND, "IND"; OINDREG, "INDREG"; OINIT, "INIT";
  OLABEL, "LABEL"; OLDIV, "LDIV"; OLE, "LE"; OLIST, "LIST"; OLMOD, "LMOD"; OLMUL, "LMUL"; OLO, "LO"; OLS, "LS";
  OLSHR, "LSHR"; OLT, "LT"; OMOD, "MOD"; OMUL, "MUL"; ONAME, "NAME"; ONE, "NE"; ONOT, "NOT"; OOR, "OR";
  OOROR, "OROR"; OPOSTDEC, "POSTDEC"; OPOSTINC, "POSTINC"; OPREDEC, "PREDEC"; OPREINC, "PREINC"; OPROTO, "PROTO";
  OREGISTER, "REGISTER"; ORETURN, "RETURN"; OSET, "SET"; OSIGN, "SIGN"; OSIZE, "SIZE"; OSTRING, "STRING";
  OLSTRING, "LSTRING"; OSTRUCT, "STRUCT"; OSUB, "SUB"; OSWITCH, "SWITCH"; OUNION, "UNION"; OUSED, "USED";
  OWHILE, "WHILE"; OXOR, "XOR"; ONEG, "NEG"; OCOM, "COM"; OPOS, "POS"; OELEM, "ELEM"; OTST, "TST"; OINDEX, "INDEX";
  OFAS, "FAS"; OREGPAIR, "REGPAIR"; OEXREG, "EXREG" ]
let opname o = List.assoc o opnames

type sym = {
  name : string;
  mutable typ : typ option;
  mutable suetag : typ option;
  mutable tenum : typ option;
  mutable macro : string option;     (* its first char is its number of arguments + 1, as mac.c *)
  mutable soffset : int;
  mutable svconst : int64;
  mutable sfconst : float;
  mutable label : node option;
  mutable lexical : int;              (* the token: a name or a keyword *)
  mutable block : int;
  mutable sueblock : int;
  mutable sclass : cls;
  mutable aused : bool;
}

and typ = {
  mutable tsym : sym option;          (* a structure element's name *)
  mutable tag : sym option;
  mutable link : typ option;
  mutable down : typ option;
  mutable width : int;
  mutable offset : int;
  mutable etype : etype;
  mutable garb : int;
}

and node = {
  mutable left : node option;
  mutable right : node option;
  mutable pc : int;
  mutable reg : int;
  mutable xoffset : int;
  mutable fconst : float;
  mutable vconst : int64;
  mutable cstring : string;
  mutable nsym : sym option;
  mutable ntype : typ option;
  mutable lineno : int;
  mutable op : op;
  mutable nclass : cls;
  mutable complex : int;
  mutable addable : int;
  mutable ngarb : int;
}

(* the machine, as the front end sees it: widths and alignment
 * (goken's ewidth, align, maxround in each back end's swt.c and gc.h) *)
type machine = {
  thechar : char;
  sz_ind : int;
  maxalign : int;                     (* SZ_LONG on arm, SZ_VLONG on arm64 *)
  typecmplx : etype -> bool;             (* returned through a pointer *)
  typeword : etype -> bool;              (* passed in a register *)
  typeswitch : etype -> bool;
  machcap : node option -> bool;      (* what the back end does itself *)
}

let mach : machine option ref = ref None
let m () = Option.get !mach

let ewidth = function
  | Tchar | Tuchar -> 1
  | Tshort | Tushort -> 2
  | Tint | Tuint | Tlong | Tulong | Tfloat | Tenum -> 4
  | Tvlong | Tuvlong | Tdouble -> 8
  | Tind -> (m ()).sz_ind
  | Tfunc | Tvoid -> 0
  | _ -> -1

(* a conversion that makes no code: to itself, between integers of a
 * size, an integer to a pointer of its size, a pointer to a long (arm)
 * or a vlong (arm64) (txt.c's ncast tables) *)
let ncast from to_ =
  from = to_ && (typefd from || typesu from || from = Tind)
  || ewidth from = ewidth to_ && (typei from && (typei to_ || to_ = Tind) || from = Tind && List.mem to_ [ Tlong; Tulong; Tvlong; Tuvlong ])

(* a constant as a type holds it (com64.c's convvtox) *)
let convvtox (c : int64) et =
  let n = 8 * ewidth et in
  if n >= 64 then c
  else
    let c = Int64.logand c (Int64.pred (Int64.shift_left 1L n)) in
    if (not (typeu (et))) && Int64.logand c (Int64.shift_left 1L (n - 1)) <> 0L then Int64.logor c (Int64.shift_left (-1L) n) else c

(*****************************************************************************)
(* Constructors (sub.c) *)
(*****************************************************************************)

let lineno = ref 1
let nearln = ref 0

let mk op l r =
  let lineno = match l, r with Some l, _ when op <> OGOTO -> l.lineno | _, Some r -> r.lineno | _ -> !lineno in
  { left = l; right = r; pc = 0; reg = 0; xoffset = 0; fconst = 0.; vconst = 0L; cstring = ""; nsym = None; ntype = None;
    lineno; op; nclass = Cxxx; complex = 0; addable = 0; ngarb = 0 }

let node op l r = mk op l r
(* new1: at the line being diagnosed *)
let node1 op l r = let n = mk op l r in n.lineno <- !nearln; n

(* *n = *m *)
let copy_into (n : node) (m : node) =
  n.left <- m.left; n.right <- m.right; n.pc <- m.pc; n.reg <- m.reg; n.xoffset <- m.xoffset; n.fconst <- m.fconst;
  n.vconst <- m.vconst; n.cstring <- m.cstring; n.nsym <- m.nsym; n.ntype <- m.ntype; n.lineno <- m.lineno;
  n.op <- m.op; n.nclass <- m.nclass; n.complex <- m.complex; n.addable <- m.addable; n.ngarb <- m.ngarb

let dup (m : node) = { m with op = m.op }

let typ et d =
  { tsym = None; tag = None; link = d; down = None; width = ewidth et; offset = 0; etype = et; garb = 0 }

let copytyp (t : typ) = { t with etype = t.etype }

(* the basic types, one of each (lex.c's cinit) *)
let types : (etype, typ) Hashtbl.t = Hashtbl.create 16
let ty et = Hashtbl.find types et

let init_types () =
  let set et t = Hashtbl.replace types et t in
  List.iter (fun et -> set et (typ et None))
    [ Tchar; Tuchar; Tshort; Tushort; Tint; Tuint; Tlong; Tulong; Tvlong; Tuvlong; Tfloat; Tdouble; Tvoid; Tenum ];
  set Tfunc (typ Tfunc (Some (ty Tint)));
  set Tind (typ Tind (Some (ty Tvoid)))

(* the accessors, where a C pointer is sure not to be nil *)
let l n = Option.get n.left
let r n = Option.get n.right
let t n = Option.get n.ntype
let et n = match n.ntype with Some t -> t.etype | None -> Txxx
let link t = Option.get t.link
let sym n = Option.get n.nsym

(*****************************************************************************)
(* Symbols (lex.c's lookup, and its hash) *)
(*****************************************************************************)

let nhash = 1024
let hash : sym list array = Array.make nhash []

(* h = h*3 + c over an unsigned 64-bit long; complemented if negative *)
let bucket name =
  let h = ref 0L in
  String.iter (fun c -> h := Int64.add (Int64.mul !h 3L) (Int64.of_int (Char.code c))) name;
  let h = if Int64.compare !h 0L < 0 then Int64.lognot !h else !h in
  Int64.to_int (Int64.unsigned_rem h (Int64.of_int nhash))

let lookup name =
  let h = bucket name in
  match List.find_opt (fun s -> s.name = name) hash.(h) with
  | Some s -> s
  | None ->
      let s = { name; typ = None; suetag = None; tenum = None; macro = None; soffset = 0; svconst = 0L;
                sfconst = 0.; label = None; lexical = 0; block = 0; sueblock = 0; sclass = Cxxx; aused = false } in
      hash.(h) <- s :: hash.(h);
      s

exception Error of string

let errors = ref 0
let error_at line fmt = Printf.ksprintf (fun s -> incr errors; raise (Error (Printf.sprintf "%d: %s" line s))) fmt
let diag (n : node option) fmt = error_at (match n with Some n -> n.lineno | None -> !nearln) fmt

(*****************************************************************************)
(* The same type (dcl.c's sametype) *)
(*****************************************************************************)

(* a structure known only by its tag gets its elements (dcl.c's snap) *)
let snap (t : typ) =
  if typesu (t.etype) && t.link = None then
    match t.tag with
    | Some { suetag = Some st; _ } -> t.link <- st.link; t.width <- st.width
    | _ -> ()

let rec rsametype (t1 : typ option) (t2 : typ option) n f =
  let n = n - 1 in
  let rec loop t1 t2 =
    match t1, t2 with
    | _ when t1 == t2 -> true
    | Some a, Some b when a == b -> true
    | None, _ | _, None -> false
    | Some a, Some b ->
        if n <= 0 then true
        else if a.etype <> b.etype then false
        else if a.etype = Tfunc then
          if not (rsametype a.link b.link n false) then false
          else
            let rec args t1 t2 =
              match t1, t2 with
              | Some x, _ when x.etype = Told -> args x.down t2
              | _, Some y when y.etype = Told -> args t1 y.down
              | Some _, Some _ ->
                  let rec each t1 t2 =
                    match t1, t2 with
                    | None, None -> true
                    | _ -> rsametype t1 t2 n false && each (Option.bind t1 (fun t -> t.down)) (Option.bind t2 (fun t -> t.down))
                  in
                  each t1 t2
              | _ -> true
            in
            args a.down b.down
        else if a.etype = Tarray && a.width <> b.width && a.width <> 0 && b.width <> 0 then false
        else if typesu (a.etype) then begin
          if a.link = None then snap a;
          if b.link = None then snap b;
          if a != b && a.link = None && b.link = None
             && (match a.tag, b.tag with Some x, Some y -> x.name <> y.name | _ -> true) then false
          else
            let rec els t1 t2 =
              match t1, t2 with
              | _ when t1 == t2 -> true
              | Some x, Some y when x == y -> true
              | _ -> rsametype t1 t2 n false && els (Option.bind t1 (fun t -> t.down)) (Option.bind t2 (fun t -> t.down))
            in
            els a.link b.link
        end
        else begin
          let t1 = a.link and t2 = b.link in
          if f && a.etype = Tind
             && ((match t1 with Some t -> t.etype = Tvoid | None -> false) || (match t2 with Some t -> t.etype = Tvoid | None -> false))
          then true
          else loop t1 t2
        end
  in
  loop t1 t2

let sametype (t1 : typ option) (t2 : typ option) =
  match t1, t2 with
  | Some a, Some b when a == b -> true
  | None, None -> true
  | _ -> rsametype t1 t2 5 true

(*****************************************************************************)
(* Printing (sub.c's prtree, lex.c's Tconv): the -x dump *)
(*****************************************************************************)

let rec show_type (t : typ option) =
  let b = Buffer.create 32 in
  let rec go (t : typ option) =
    match t with
    | None -> ()
    | Some t ->
        if Buffer.length b > 0 then Buffer.add_char b ' ';
        if t.garb land lnot gincomplete <> 0 then (Buffer.add_string b gnames.(t.garb land lnot gincomplete); Buffer.add_char b ' ');
        Buffer.add_string b (tname t.etype);
        if t.etype = Tfunc && t.down <> None then begin
          Buffer.add_string b "(";
          let rec args (d : typ option) first =
            match d with
            | None -> ()
            | Some d ->
                if not first then Buffer.add_string b ", ";
                Buffer.add_string b (show_type (Some d));
                args d.down false
          in
          args t.down true;
          Buffer.add_string b ")"
        end;
        if t.etype = Tarray then begin
          let n = match t.link with Some l when l.width <> 0 -> t.width / l.width | _ -> t.width in
          Buffer.add_string b (Printf.sprintf "[%d]" n)
        end;
        if typesu (t.etype) then Buffer.add_string b (match t.tag with Some s -> " " ^ s.name | None -> " {}")
        else go t.link
  in
  go t;
  Buffer.contents b

let fnname (n : node option) =
  match n with Some ({ op = ONAME | ODOT | OELEM; nsym = Some s; _ }) -> s.name | _ -> "<indirect>"

let prtree (n : node option) title =
  let b = Buffer.create 256 in
  Buffer.add_string b (Printf.sprintf " == %s ==\n" title);
  let rec go (n : node option) d f =
    if f then for _ = 1 to d do Buffer.add_string b "   " done;
    match n with
    | None -> Buffer.add_string b "Z\n"
    | Some ({ op = OLIST; _ } as n) -> go n.left d false; go n.right d true
    | Some n ->
        let d = d + 1 in
        Buffer.add_string b (opname n.op);
        let kids =
          match n.op with
          | ONAME -> Buffer.add_string b (Printf.sprintf " \"%s\" %d" (fnname (Some n)) (n.xoffset land 0xffffffff)); 0
          | OINDREG -> Buffer.add_string b (Printf.sprintf " %d(R%d)" n.xoffset n.reg); 0
          | OREGISTER -> Buffer.add_string b (if n.xoffset <> 0 then Printf.sprintf " %d+R%d" n.xoffset n.reg else Printf.sprintf " R%d" n.reg); 0
          | OSTRING ->
              (* %s: up to a NUL *)
              let s = match String.index_opt n.cstring '\000' with Some i -> String.sub n.cstring 0 i | None -> n.cstring in
              Buffer.add_string b (Printf.sprintf " \"%s\"" s); 0
          | OLSTRING -> Buffer.add_string b " \"...\""; 0
          | ODOT | OELEM -> Buffer.add_string b (Printf.sprintf " \"%s\"" (fnname (Some n))); 3
          | OCONST ->
              Buffer.add_string b (if typefd (et n) then Printf.sprintf " \"%.8e\"" n.fconst else Printf.sprintf " \"%Ld\"" n.vconst); 0
          | _ -> 3
        in
        if n.addable <> 0 then Buffer.add_string b (Printf.sprintf " <%d>" n.addable);
        if n.ntype <> None then Buffer.add_string b (" " ^ show_type n.ntype);
        if n.complex <> 0 then Buffer.add_string b (Printf.sprintf " (%d)" n.complex);
        Buffer.add_string b (Printf.sprintf " %d\n" n.lineno);
        if kids land 2 <> 0 then go n.left d true;
        if kids land 1 <> 0 then go n.right d true
  in
  go n 0 false;
  Buffer.add_string b "\n";
  Buffer.contents b
