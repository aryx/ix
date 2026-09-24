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

(* a type's kind, then the other words of a declaration: one numbering,
 * for a declaration's words are a set of bits (cc.h's TCHAR... BAUTO...) *)
type etype =
  | Txxx | Tchar | Tuchar | Tshort | Tushort | Tint | Tuint | Tlong | Tulong | Tvlong | Tuvlong | Tfloat | Tdouble
  | Tind | Tfunc | Tarray | Tvoid | Tstruct | Tunion | Tenum | Tdot
  | Tauto | Textern | Tstatic | Ttypedef | Ttypestr | Tregister | Tconstnt | Tvolatile | Tunsigned | Tsigned | Tfile | Told

(* constant constructors are their index *)
let rank (t : etype) = (Obj.magic t : int)
let b t = 1 lsl rank t
let bits l = List.fold_left (fun a t -> a lor b t) 0 l

let integers = [ Tchar; Tuchar; Tshort; Tushort; Tint; Tuint; Tlong; Tulong; Tvlong; Tuvlong ]
let binteger = bits integers
let bnumber = binteger lor b Tfloat lor b Tdouble
let bclass = bits [ Tauto; Textern; Tstatic; Ttypedef; Ttypestr; Tregister ]
let bgarb = b Tconstnt lor b Tvolatile

(* the sets are named by their members' initials, as sub.c's: typechlp
 * is char, short, long (of each sign) and pointer *)
let set l t = List.mem t l
let typei = set integers
let typeu = set [ Tuchar; Tushort; Tuint; Tulong; Tuvlong; Tind ]
let typesuv = set [ Tvlong; Tuvlong; Tstruct; Tunion ]
let typeilp = set [ Tint; Tuint; Tlong; Tulong; Tind ]
let chl = [ Tchar; Tuchar; Tshort; Tushort; Tint; Tuint; Tlong; Tulong ]
let typechl = set chl
let typechlv = set integers
let typechlvp = set (Tind :: integers)
let typechlp = set (Tind :: chl)
let typev = set [ Tvlong; Tuvlong ]
let typefd = set [ Tfloat; Tdouble ]
let typeaf = set [ Tfunc; Tarray ]
let typesu = set [ Tstruct; Tunion ]

(* which types an operator takes, by its left type: a set of right types
 * as bits (sub.c's tasign, tadd...) *)
let table l t = match List.assoc_opt t l with Some v -> v | None -> 0
let numbers = List.map (fun t -> t, bnumber) (integers @ [ Tfloat; Tdouble ])
let tasign = table (numbers @ [ Tind, b Tind; Tstruct, b Tstruct; Tunion, b Tunion ])
let tasadd = table (numbers @ [ Tind, binteger ])
let tcast = table (List.map (fun t -> t, bnumber lor b Tind lor b Tvoid) integers
                   @ [ Tfloat, bnumber lor b Tvoid; Tdouble, bnumber lor b Tvoid; Tind, binteger lor b Tind lor b Tvoid;
                       Tvoid, b Tvoid; Tstruct, b Tstruct lor b Tvoid; Tunion, b Tunion lor b Tvoid ])
let tadd = table (List.map (fun (t, v) -> t, if typefd t then v else v lor b Tind) numbers @ [ Tind, binteger ])
let tsub = table (numbers @ [ Tind, binteger lor b Tind ])
let tmul = table numbers
let tand = table (List.map (fun t -> t, if t = Tint || t = Tuint then bnumber else binteger) integers)
let trel = table (numbers @ [ Tind, b Tind ])
(* whatever the left type *)
let tfunct _ = b Tfunc and tindir _ = b Tind and tdots _ = b Tstruct lor b Tunion
and tnot _ = bnumber lor b Tind and targ _ = bnumber lor b Tind lor b Tstruct lor b Tunion

(* the usual arithmetic conversions: the type of l op r (sub.c's tab,
 * with its quirks: no promotion, double op float is float) *)
let arith_tab (l : etype) (r : etype) =
  let rows = [
    [ Tchar; Tuchar; Tshort; Tushort; Tint; Tuint; Tlong; Tulong; Tvlong; Tuvlong; Tfloat; Tdouble; Tind ];
    [ Tuchar; Tuchar; Tushort; Tushort; Tuint; Tuint; Tulong; Tulong; Tuvlong; Tuvlong; Tfloat; Tdouble; Tind ];
    [ Tshort; Tushort; Tshort; Tushort; Tint; Tuint; Tlong; Tulong; Tvlong; Tuvlong; Tfloat; Tdouble; Tind ];
    [ Tushort; Tushort; Tushort; Tushort; Tuint; Tuint; Tulong; Tulong; Tuvlong; Tuvlong; Tfloat; Tdouble; Tind ];
    [ Tint; Tuint; Tint; Tuint; Tint; Tuint; Tlong; Tulong; Tvlong; Tuvlong; Tfloat; Tdouble; Tind ];
    [ Tuint; Tuint; Tuint; Tuint; Tuint; Tuint; Tulong; Tulong; Tuvlong; Tuvlong; Tfloat; Tdouble; Tind ];
    [ Tlong; Tulong; Tlong; Tulong; Tlong; Tulong; Tlong; Tulong; Tvlong; Tuvlong; Tfloat; Tdouble; Tind ];
    [ Tulong; Tulong; Tulong; Tulong; Tulong; Tulong; Tulong; Tulong; Tuvlong; Tuvlong; Tfloat; Tdouble; Tind ];
    [ Tvlong; Tuvlong; Tvlong; Tuvlong; Tvlong; Tuvlong; Tvlong; Tuvlong; Tvlong; Tuvlong; Tfloat; Tdouble; Tind ];
    [ Tuvlong; Tuvlong; Tuvlong; Tuvlong; Tuvlong; Tuvlong; Tuvlong; Tuvlong; Tuvlong; Tuvlong; Tfloat; Tdouble; Tind ];
    [ Tfloat; Tfloat; Tfloat; Tfloat; Tfloat; Tfloat; Tfloat; Tfloat; Tfloat; Tfloat; Tfloat; Tdouble; Tind ];
    [ Tdouble; Tdouble; Tdouble; Tdouble; Tdouble; Tdouble; Tdouble; Tdouble; Tdouble; Tdouble; Tfloat; Tdouble; Tind ];
    List.init 13 (fun _ -> Tind) ] in
  let i = rank l and j = rank r in
  if i < 1 || i > 13 || j < 1 || j > 13 then Txxx else List.nth (List.nth rows (i - 1)) (j - 1)

(* char and short to int, keeping the sign *)
let promote = function Tchar | Tshort -> Tint | Tuchar | Tushort -> Tuint | t -> t

let tname t = List.nth [ "TXXX"; "CHAR"; "UCHAR"; "SHORT"; "USHORT"; "INT"; "UINT"; "LONG"; "ULONG"; "VLONG";
  "UVLONG"; "FLOAT"; "DOUBLE"; "IND"; "FUNC"; "ARRAY"; "VOID"; "STRUCT"; "UNION"; "ENUM"; "DOT"; "AUTO"; "EXTERN";
  "STATIC"; "TYPEDEF"; "TYPESTR"; "REGISTER"; "CONSTNT"; "VOLATILE"; "UNSIGNED"; "SIGNED"; "FILE"; "OLD" ] (rank t)

(* storage classes, and qualifiers (GCONSTNT...) *)
type cls = Cxxx | Cauto | Cextern | Cglobl | Cstatic | Clocal | Ctypedef | Ctypestr | Cparam | Cselem | Clabel | Cexreg
let cname (c : cls) = List.nth [ "CXXX"; "AUTO"; "EXTERN"; "GLOBL"; "STATIC"; "LOCAL"; "TYPEDEF"; "TYPESTR"; "PARAM";
  "SELEM"; "LABEL"; "EXREG" ] (Obj.magic c : int)
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

let onames = [| "OXXX"; "ADD"; "ADDR"; "AND"; "ANDAND"; "ARRAY"; "AS"; "ASI"; "ASADD"; "ASAND"; "ASASHL"; "ASASHR";
  "ASDIV"; "ASHL"; "ASHR"; "ASLDIV"; "ASLMOD"; "ASLMUL"; "ASLSHR"; "ASMOD"; "ASMUL"; "ASOR"; "ASSUB"; "ASXOR";
  "BIT"; "BREAK"; "CASE"; "CAST"; "COMMA"; "COND"; "CONST"; "CONTINUE"; "DIV"; "DOT"; "DOTDOT"; "DWHILE"; "ENUM";
  "EQ"; "FOR"; "FUNC"; "GE"; "GOTO"; "GT"; "HI"; "HS"; "IF"; "IND"; "INDREG"; "INIT"; "LABEL"; "LDIV"; "LE";
  "LIST"; "LMOD"; "LMUL"; "LO"; "LS"; "LSHR"; "LT"; "MOD"; "MUL"; "NAME"; "NE"; "NOT"; "OR"; "OROR"; "POSTDEC";
  "POSTINC"; "PREDEC"; "PREINC"; "PROTO"; "REGISTER"; "RETURN"; "SET"; "SIGN"; "SIZE"; "STRING"; "LSTRING";
  "STRUCT"; "SUB"; "SWITCH"; "UNION"; "USED"; "WHILE"; "XOR"; "NEG"; "COM"; "POS"; "ELEM"; "TST"; "INDEX";
  "FAS"; "REGPAIR"; "EXREG" |]
(* constant constructors are their index *)
let opname (o : op) = onames.((Obj.magic o : int))

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
  ncast : etype -> int;                  (* the casts that are no-ops *)
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
let types : typ option array = Array.make (rank Tdot + 1) None
let ty et = Option.get types.(rank et)

let init_types () =
  let set et t = types.(rank et) <- Some t in
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
