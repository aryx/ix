(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Declare.mli *)

open Tree

(* the back end's, set by Gen: an initializer's data (swt.c's gextern) *)
(* a function's name and its body, parsed: to the code generator *)
let on_function : (node -> node -> unit) ref = ref (fun _ _ -> ())

let gextern : (sym -> node -> int -> int -> unit) ref = ref (fun _ _ _ _ -> ())

(*****************************************************************************)
(* The state of the declarations (cc.h's globals) *)
(*****************************************************************************)

let autoffset = ref 0
let stkoff = ref 0
let blockno = ref 0
let autobn = ref 0
let lastdcl : typ option ref = ref None
let lasttype : typ option ref = ref None
let lastclass = ref Cxxx
let lastfield = ref 0
let strf : typ option ref = ref None
let strl : typ option ref = ref None
let taggen = ref 0
let firstarg : sym option ref = ref None
let firstargtype : typ option ref = ref None
let thisfn : typ option ref = ref None
let initlist : node option ref = ref None
let en_tenum : typ option ref = ref None
let en_cenum : typ option ref = ref None
let en_lastenum = ref 0L
let en_floatenum = ref 0.

(* what the end of a block undoes, the last first: its mark, the
 * declarations its names hid, the tags; a function's labels at its end *)
type undo =
  | Mark of int * int                 (* the offset of the autos, the block *)
  | Name of sym * typ option * cls * int * int * bool   (* its type, class, offset, block, used *)
  | Tag of sym * typ option * int

let dclstack : undo list ref = ref []
let labels : sym list ref = ref []

let push1 (s : sym) = dclstack := Name (s, s.typ, s.sclass, s.soffset, s.block, s.aused) :: !dclstack

(*****************************************************************************)
(* Alignment, by the machine (each back end's swt.c) *)
(*****************************************************************************)

(* an element's start and end, a structure's end, the frame's
 * first parameter (a structure's result's address), a parameter's start
 * and end, an auto *)
type align = Ael1 | Ael2 | Asu2 | Aarg0 | Aarg1 | Aarg2 | Aaut3

let round v w =
  if w <= 0 || w > 8 then ignore (diag None "rounding by %d" w);
  let r = v mod w in
  if r <> 0 then v + w - r else v

let rec align i (t : typ) op =
  let ma = (m ()).maxalign in
  let o, w =
    match op with
    | Asu2 -> i, ma
    | Ael1 ->
        let rec base (v : typ) = if v.etype = Tarray then base (link v) else v in
        let w = ewidth (base t).etype in
        i, if w <= 0 || w >= ma then ma else w
    | Ael2 -> i + t.width, 1
    | Aarg0 -> (if (m ()).typecmplx t.etype then align (align i (ty Tind) Aarg1) (ty Tind) Aarg2 else i), 1
    | Aarg1 -> let w = ewidth t.etype in i, if w <= 0 || w >= ma then ma else 1
    | Aarg2 -> i + t.width, ma
    | Aaut3 -> align (align i t Ael2) t Ael1, 4
  in
  round o w

let maxround max v = let v = round v (m ()).maxalign in if v > max then v else max

(*****************************************************************************)
(* The words of a declaration (sub.c's simplet, simplec, simpleg) *)
(*****************************************************************************)

(* a declaration's words, in the order C allows them anywhere *)
type word =
  | Char | Short | Int | Long | Signed | Unsigned | Float | Double | Void
  | Auto | Static | Extern | Typedef | Typestr | Register | Const | Volatile

let words_of kind ws = List.sort_uniq compare (List.filter (fun w -> List.mem w kind) ws)
let type_words = [ Char; Short; Int; Long; Signed; Unsigned; Float; Double; Void ]

let simpleg ws = (if List.mem Const ws then gconstnt else 0) lor (if List.mem Volatile ws then gvolatile else 0)

let simplec ws =
  match words_of [ Auto; Static; Extern; Typedef; Typestr; Register ] ws with
  | [] | [ Register ] -> Cxxx
  | [ Auto ] | [ Auto; Register ] -> Cauto
  | [ Static ] -> Cstatic
  | [ Extern ] -> Cextern
  | [ Extern; Register ] -> Cexreg
  | [ Typedef ] -> Ctypedef
  | [ Typestr ] -> Ctypestr
  | _ -> diag None "illegal combination of classes"

(* the type the words say: int by default, long long a vlong *)
let simplet ws =
  let has w = List.mem w ws and longs = List.length (List.filter (( = ) Long) ws) in
  let plain = not (has Int || has Signed || has Unsigned) in
  let sign s u = Some (if has Unsigned then u else s) in
  let t =
    if has Signed && has Unsigned then None
    else
      match List.filter (fun w -> not (List.mem w [ Int; Signed; Unsigned ])) (words_of type_words ws) with
      | [] -> sign Tint Tuint
      | [ Char ] when not (has Int) -> sign Tchar Tuchar
      | [ Short ] -> sign Tshort Tushort
      | [ Long ] when longs >= 2 -> sign Tvlong Tuvlong
      | [ Long ] -> sign Tlong Tulong
      | [ Float ] when plain -> Some Tfloat
      | ([ Double ] | [ Long; (Float | Double) ]) when plain && longs <= 1 -> Some Tdouble
      | [ Void ] when plain -> Some Tvoid
      | _ -> None
  in
  match t with Some t -> ty t | None -> diag None "illegal combination of types"

let garbt (t : typ) ws = if simpleg ws <> 0 then (let t1 = copytyp t in t1.garb <- simpleg ws; t1) else t

(*****************************************************************************)
(* Declarators (dcl.c's dodecl) *)
(*****************************************************************************)

(* a local static, as a global of its own (dcl.c's mkstatic) *)
let mkstatic (s : sym) =
  if s.sclass <> Clocal then s
  else begin
    let s1 = lookup (Printf.sprintf "%s$%d" s.name s.block) in
    if s1.sclass <> Cstatic then (s1.typ <- s.typ; s1.soffset <- s.soffset; s1.block <- s.block; s1.sclass <- Cstatic);
    s1
  end

(* declare the names of n, whose types are around them: t of class c,
 * given to f (xdecl, adecl, pdecl, edecl; or none) *)
let rec dodecl (f : (cls -> typ -> sym option -> unit) option) c (t : typ) (n : node option) : node option =
  nearln := !lineno;
  lastfield := 0;
  let rec loop (t : typ) (n : node option) =
    match n with
    | None -> lastdcl := Some t; n
    | Some nn -> (
        match nn.op with
        | OARRAY ->
            let t = typ Tarray (Some t) in
            t.width <- 0;
            (match nn.right with
             | Some n1 ->
                 Check.complex (Some n1);
                 let v = if n1.op = OCONST then Int64.to_int n1.vconst else -1 in
                 let v = if v <= 0 then (ignore (diag n "array size must be a positive constant"); 1) else v in
                 t.width <- v * (link t).width
             | None -> ());
            loop t nn.left
        | OIND -> let t = typ Tind (Some t) in t.garb <- nn.ngarb; loop t nn.left
        | OFUNC -> let t = typ Tfunc (Some t) in t.down <- fnproto nn; loop t nn.left
        | OBIT -> diag n "bitfields are not in the subset"
        | ONAME ->
            (match f with
             | None -> ()
             | Some f ->
                 let s = sym nn in
                 f c t (Some s);
                 let s = if s.sclass = Clocal then mkstatic s else s in
                 nn.nsym <- Some s; nn.ntype <- s.typ; nn.xoffset <- s.soffset; nn.nclass <- s.sclass;
                 
                 );
            lastdcl := Some t;
            n
        | o -> diag n "unknown declarator: %s" (opname o))
  in
  loop t n

(* the arguments' types, from a prototype (dcl.c's fnproto) *)
and anyproto (n : node option) =
  let rec go (n : node option) r =
    match n with
    | None -> r
    | Some ({ op = OLIST; _ } as n) -> go n.right (r lor go n.left 0)
    | Some { op = ODOTDOT | OPROTO; _ } -> r lor 1
    | Some _ -> r lor 2
  in
  go n 0

and fnproto (n : node) =
  let r = anyproto n.right in
  if r = 0 || r land 2 <> 0 then (if r land 1 <> 0 then ignore (diag (Some n) "mixed ansi/old function declaration"); None)
  else fnproto1 n.right

and fnproto1 (n : node option) : typ option =
  match n with
  | None -> None
  | Some ({ op = OLIST; _ } as n) ->
      let t = fnproto1 n.left in
      (match t with Some t -> t.down <- fnproto1 n.right | None -> ());
      t
  | Some ({ op = OPROTO; _ } as n) ->
      lastdcl := None;
      ignore (dodecl None Cxxx (Tree.t n) n.left);
      (* a copy: the prototype's list is its own *)
      Some (match !lastdcl with Some ld -> copytyp (paramconv ld true) | None -> typ Txxx None)
  | Some ({ op = ONAME; _ } as n) -> ignore (diag (Some n) "incomplete argument prototype"); Some (typ Tint None)
  | Some { op = ODOTDOT; _ } -> Some (typ Tdot None)
  | Some n -> diag (Some n) "unknown op in fnproto"

and paramconv (t : typ) f =
  if t.etype = Tarray then (let t = typ Tind t.link in t.width <- (ty Tind).width; t)
  else if t.etype = Tfunc then (let t' = typ Tind (Some t) in t'.width <- (ty Tind).width; t')
  else if not f && t.etype = Tfloat then ty Tdouble
  else if not f && (t.etype = Tchar || t.etype = Tshort) then ty Tint
  else if not f && (t.etype = Tuchar || t.etype = Tushort) then ty Tuint
  else t

(*****************************************************************************)
(* The kinds of declaration *)
(*****************************************************************************)

(* a merge of a new declaration of s into its old (dcl.c's tmerge) *)
let tmerge (t1 : typ) (s : sym) =
  let rec go (t1 : typ option) (t2 : typ option) =
    match t1, t2 with
    | Some a, Some b' when a != b' && a.etype = b'.etype ->
        if a.etype = Tfunc then begin
          (match a.down, b'.down with
           | None, tb -> a.down <- tb
           | _, None -> ()
           | Some ta, Some tb ->
               if ta.etype = Told && tb.etype <> Told then a.down <- Some tb);
          go a.link b'.link
        end
        else if a.etype = Tarray then (if b'.width > a.width then a.width <- b'.width; go a.link b'.link)
        else if typesu (a.etype) then ()
        else go a.link b'.link
    | _ -> ()
  in
  go (Some t1) s.typ

(* a parameter's offset, after the previous one's *)
let param (s : sym option) (t : typ) =
  if !autoffset = 0 then (firstarg := s; firstargtype := Some t);
  autoffset := align !autoffset t Aarg1;
  Option.iter (fun s -> s.soffset <- !autoffset) s;
  autoffset := align !autoffset t Aarg2

let adecl c (t : typ) (s : sym option) =
  let c = if c = Cstatic then Clocal else c in
  let c =
    if t.etype = Tfunc then (if c = Cxxx then Cextern else if c = Clocal then Cstatic else c) else c in
  let c = if c = Cxxx then Cauto else c in
  (match s with
   | Some s ->
       if (s.sclass = Cauto || s.sclass = Cparam || s.sclass = Clocal) && s.block = !autobn then
         ignore (diag None "auto redeclaration of: %s" s.name);
       if c <> Cparam then push1 s;
       s.block <- !autobn; s.soffset <- 0; s.typ <- Some t; s.sclass <- c; s.aused <- false
   | None -> ());
  if c = Cauto then begin
    autoffset := align !autoffset t Aaut3;
    stkoff := maxround !stkoff !autoffset;
    Option.iter (fun s -> s.soffset <- - !autoffset) s
  end
  else if c = Cparam then param s t

let pdecl c (t : typ) (s : sym option) =
  (match s with Some s when s.soffset <> -1 -> ignore (diag None "not a parameter: %s" s.name) | _ -> ());
  let t = paramconv t (c = Cparam) in
  if c <> Cxxx && c <> Cparam then ignore (diag None "parameter cannot have class");
  adecl Cparam t s

let xdecl c (t : typ) (s : sym option) =
  let s = Option.get s in
  let c =
    if c = Cextern then (if s.sclass = Cglobl then Cglobl else Cextern)
    else if c = Cxxx then (if s.sclass = Cextern then s.sclass <- Cglobl; Cglobl)
    else if c = Cauto then Cextern
    else if c = Cexreg then (if s.sclass = Cglobl then Cglobl else Cextern)
    else c
  in
  let c = if s.sclass = Cstatic && (c = Cextern || c = Cglobl) then Cstatic else c in
  if s.typ <> None && (s.sclass <> c || not (sametype (Some t) s.typ) || t.etype = Tenum) then
    ignore (diag None "external redeclaration of: %s" s.name);
  tmerge t s;
  s.typ <- Some t; s.sclass <- c; s.block <- 0; s.soffset <- 0

(* a structure's element (dcl.c's edecl) *)
let edecl c (t : typ) (s : sym option) =
  (match s with
   | None -> if not (typesu (t.etype)) then ignore (diag None "unnamed structure element must be struct/union")
   | Some _ -> ());
  if c <> Cxxx then ignore (diag None "structure element cannot have class");
  let t = copytyp t in
  t.tsym <- s; t.down <- None;
  (match !strf with None -> strf := Some t | Some _ -> (Option.get !strl).down <- Some t);
  strl := Some t

(* the offsets of a structure's elements, its width (dcl.c's sualign) *)
let sualign (t : typ) =
  let rec els (e : typ option) = match e with None -> [] | Some e -> e :: els e.down in
  if t.etype = Tstruct then begin
    t.offset <- 0;
    let w = List.fold_left (fun w (e : typ) ->
      if e.width < 0 || (e.width = 0 && e.down <> None) then ignore (diag None "incomplete structure element");
      let w = align w e Ael1 in
      e.offset <- w;
      align w e Ael2) 0 (els t.link) in
    t.width <- align w t Asu2
  end
  else if t.etype = Tunion then begin
    t.offset <- 0;
    let w = List.fold_left (fun w (e : typ) ->
      if e.width <= 0 then ignore (diag None "incomplete union element");
      e.offset <- 0;
      max w (align (align 0 e Ael1) e Ael2)) 0 (els t.link) in
    t.width <- align w t Asu2
  end
  else ignore (diag None "unknown type in sualign")

(* a copy of a typedef whose incomplete arrays are the variable's
 * (dcl.c's tcopy) *)
let rec tcopy (t : typ option) : typ option =
  match t with
  | None -> None
  | Some t when typesu (t.etype) -> Some t
  | Some t ->
      let tl = tcopy t.link in
      if (match tl, t.link with Some a, Some b' -> a != b' | None, None -> false | _ -> true) || (t.etype = Tarray && t.width = 0) then begin
        let tx = copytyp t in tx.link <- tl; Some tx
      end
      else Some t

let dotag (s : sym) et bn =
  if bn <> 0 && bn <> s.sueblock then (dclstack := Tag (s, s.suetag, s.sueblock) :: !dclstack; s.suetag <- None);
  if s.suetag = None then (s.suetag <- Some (typ et None); s.sueblock <- !autobn);
  let st = Option.get s.suetag in
  if st.etype <> et then ignore (diag None "tag used for more than one type: %s" s.name);
  if st.tag = None then st.tag <- Some s;
  st

let maxtype (t1 : typ option) (t2 : typ option) =
  match t1, t2 with None, _ -> t2 | _, None -> t1 | Some a, Some b' -> if a.etype > b'.etype then t1 else t2

let doenum (s : sym) (n : node option) =
  (match n with
   | Some n ->
       Check.complex (Some n);
       if n.op <> OCONST then ignore (diag (Some n) "enum not a constant: %s" s.name);
       en_cenum := n.ntype;
       en_tenum := maxtype !en_cenum !en_tenum;
       if not (typefd ((Option.get !en_cenum).etype)) then en_lastenum := n.vconst else en_floatenum := n.fconst
   | None -> ());
  if !dclstack <> [] then push1 s;
  xdecl Cxxx (ty Tenum) (Some s);
  if !en_cenum = None then (en_tenum := Some (ty Tint); en_cenum := Some (ty Tint); en_lastenum := 0L);
  s.tenum <- !en_cenum;
  let e = (Option.get s.tenum).etype in
  if not (typefd (e)) then (s.svconst <- convvtox !en_lastenum e; en_lastenum := Int64.succ !en_lastenum)
  else (s.sfconst <- !en_floatenum; en_floatenum := !en_floatenum +. 1.)

(*****************************************************************************)
(* Blocks, parameters, labels *)
(*****************************************************************************)

let markdcl () =
  incr blockno;
  dclstack := Mark (!autoffset, !autobn) :: !dclstack;
  autobn := !blockno

(* a block's declarations undone, to its mark (and at the function's,
 * the bottom one, its labels); the volatiles' USED, to be kept *)
let revertdcl () : node option =
  let used = ref None in
  let rec go () =
    match !dclstack with
    | [] -> ignore (diag None "pop off dcl stack")
    | u :: rest ->
        dclstack := rest;
        match u with
        | Mark (o, bn) ->
            autoffset := o; autobn := bn;
            if rest = [] then (List.iter (fun (s : sym) -> s.label <- None) !labels; labels := [])
        | Name (s, t, c, o, bl, aused) ->
            (match s.typ with
             | Some tt when tt.garb land gvolatile <> 0 ->
                 let n1 = node ONAME None None in
                 n1.nsym <- Some s; n1.ntype <- s.typ; n1.xoffset <- s.soffset; n1.nclass <- s.sclass;
                 let n1 = node OUSED (Some (node OADDR (Some n1) None)) None in
                 used := (match !used with None -> Some n1 | Some x -> Some (node OLIST (Some n1) (Some x)))
             | _ -> ());
            s.typ <- t; s.sclass <- c; s.soffset <- o; s.block <- bl; s.aused <- aused;
            go ()
        | Tag (s, t, bl) -> s.suetag <- t; s.sueblock <- bl; go ()
  in
  go ();
  !used

let rec walkparam (n : node option) pass =
  match n with
  | Some { op = OPROTO; left = None; ntype = Some t; _ } when t == ty Tvoid -> ()
  | None -> ()
  | Some ({ op = OLIST; _ } as n) -> walkparam n.left pass; walkparam n.right pass
  | Some ({ op = OPROTO; _ } as n) ->
      let rec name (n1 : node option) = match n1 with None -> None | Some ({ op = ONAME; _ } as x) -> Some x | Some x -> name x.left in
      (match name (Some n) with
       | Some n1 ->
           if pass = 0 then (let s = sym n1 in push1 s; s.soffset <- -1)
           else ignore (dodecl (Some pdecl) Cparam (Tree.t n) n.left)
       | None ->
           if pass <> 0 then begin
             ignore (dodecl None Cparam (Tree.t n) n.left);
             pdecl Cparam (Option.get !lastdcl) None
           end)
  | Some { op = ODOTDOT; _ } -> ()
  | Some ({ op = ONAME; _ } as n) ->
      let s = sym n in
      if pass = 0 then (push1 s; s.soffset <- -1)
      else if s.soffset <> -1 then param (Some s) (Option.get s.typ)
      else ignore (dodecl (Some pdecl) Cxxx (ty Tint) (Some n))
  | Some n -> ignore (diag (Some n) "argument not a name/prototype")

(* the parameters' offsets; pass 1 after their old-style declarations *)
let argmark (n : node) pass =
  autoffset := align 0 (link (Option.get !thisfn)) Aarg0;
  stkoff := 0;
  let rec go (n : node) =
    match n.left with
    | None -> ()
    | Some l ->
        if n.op = OFUNC && l.op = ONAME then begin
          walkparam n.right pass;
          if pass <> 0 && anyproto n.right = 2 then ignore (diag (Some n) "old-style parameters are not in the subset")
        end
        else go l
  in
  go n;
  autoffset := 0;
  stkoff := 0

(* a label, declared (f) or used, forgotten at the function's end
 * (dcl.c's dcllabel) *)
let dcllabel (s : sym) f =
  match s.label with
  | Some n ->
      if f then (if n.complex <> 0 then ignore (diag None "label reused: %s" s.name); n.complex <- 1) else n.addable <- Alvalue;
      n
  | None ->
      labels := s :: !labels;
      let n = node OXXX None None in
      n.nsym <- Some s;
      (* defined: complex 1; used: addable, which -x prints as 5c's <1> *)
      n.complex <- (if f then 1 else 0);
      if not f then n.addable <- Alvalue;
      s.label <- Some n;
      n

(*****************************************************************************)
(* Initializers (dcl.c's doinit, init1) *)
(*****************************************************************************)

let peekinit () =
  let rec go (a : node option) = match a with Some ({ op = OLIST; _ } as a) -> go a.left | a -> a in
  go !initlist

let nextinit () : node option =
  match !initlist with
  | None -> None
  | Some a0 ->
      let a, n = if a0.op = OLIST then Tree.l a0, a0.right else a0, None in
      if a.op = OUSED then begin
        let a = Tree.l a in
        let b = node OCONST None None in
        b.ntype <- (Tree.t a).link;
        if a.op = OSTRING then begin
          b.vconst <- convvtox (Int64.of_int (if a.cstring = "" then 0 else Char.code a.cstring.[0])) Tchar;
          a.cstring <- (if a.cstring = "" then "" else String.sub a.cstring 1 (String.length a.cstring - 1))
        end;
        (Tree.t a).width <- (Tree.t a).width - (Option.get b.ntype).width;
        if (Tree.t a).width <= 0 then initlist := n;
        Some b
      end
      else (initlist := n; Some a)

let newlist (l : node option) (r : node option) = match l, r with _, None -> l | None, _ -> r | _ -> Some (node OLIST l r)

let rec doinit (s : sym) (t : typ option) o (a : node) : node option =
  match t with
  | None -> None
  | Some t ->
      if s.sclass = Cextern then s.sclass <- Cglobl;
      let saved = !initlist in
      initlist := Some (if a.op = OINIT then Tree.l a else a);
      let r = init1 s t o false in
      if !initlist <> None then ignore (diag !initlist "more initializers than structure: %s" s.name);
      initlist := saved;
      r

and isstruct (a : node) (t : typ) =
  match a.op with
  | ODOTDOT -> (match a.left with Some n when n.ntype <> None && sametype n.ntype (Some t) -> true | _ -> false)
  | OSTRING | OLSTRING | OCONST | OINIT | OELEM -> false
  | _ ->
      let n = dup a in
      a.op <- ODOTDOT; a.left <- Some n; a.right <- None;
      if Check.tcom n then false else sametype n.ntype (Some t)

and init1 (s : sym) (t : typ) o exflag : node option =
  match peekinit () with
  | None -> None
  | Some a when exflag && a.op = OINIT -> doinit s (Some t) o (Option.get (nextinit ()))
  | Some a ->
      let single () =
        if a.op = OARRAY || a.op = OELEM then None
        else
          match nextinit () with
          | None -> None
          | Some a ->
              if s.sclass = Cauto then begin
                let l = node ONAME None None in
                l.nsym <- Some s; l.ntype <- Some t; 
                l.xoffset <- s.soffset + o; l.nclass <- s.sclass;
                Some (node OASI (Some l) (Some a))
              end
              else begin
                Check.complex (Some a);
                if a.ntype = None then None
                else if a.op = OCONST then begin
                  if Check.vconst (Some a) <> 0 && t.etype = Tind && et a <> Tind then ignore (diag (Some a) "initialize pointer to an integer: %s" s.name);
                  if not (sametype a.ntype (Some t)) then begin
                    let nod = node OCAST (Some (dup a)) None in
                    nod.ntype <- Some t; nod.lineno <- a.lineno;
                    Check.complex (Some nod);
                    if nod.ntype <> None then copy_into a nod
                  end;
                  if a.op <> OCONST then ignore (diag (Some a) "initializer is not a constant: %s" s.name);
                  if Check.vconst (Some a) = 0 then None else (!gextern s a o t.width; None)
                end
                else begin
                  let rec uncast (a : node) = if a.op = OCAST then uncast (Tree.l a) else a in
                  let a = uncast a in
                  if t.etype = Tind then begin
                    if not (sametype (Some t) a.ntype) then ignore (diag (Some a) "initialization of incompatible pointers: %s" s.name);
                    !gextern s (if a.op = OADDR then Tree.l a else a) o t.width; None
                  end
                  else if a.op = OADDR then (!gextern s (Tree.l a) o t.width; None)
                  else diag (Some a) "initializer is not a constant: %s" s.name
                end
              end
      in
      let e = t.etype in
      if typei (e) || typefd (e) || e = Tind then single ()
      else if e = Tarray then begin
        let w = (link t).width in
        if (a.op = OSTRING || a.op = OLSTRING) && typei ((link t).etype) then begin
          let a = Option.get (nextinit ()) in
          let mw = t.width / w in
          let so = (Tree.t a).width / (link (Tree.t a)).width in
          if mw <> 0 && so > mw then begin
            if so <> mw + 1 then ignore (diag (Some a) "string initialization larger than array");
            (Tree.t a).width <- (Tree.t a).width - (link (Tree.t a)).width
          end;
          doinit s (Some t) o (node OUSED (Some a) None)
        end
        else begin
          let mw = ref (- w) and l = ref None and e = ref 0 in
          let rec go () =
            match peekinit () with
            | None -> ()
            | Some a when a.op = OELEM && (link t).etype <> Tstruct -> ()
            | Some a ->
                let stop =
                  if a.op = OARRAY then begin
                    if !e <> 0 && exflag then true
                    else begin
                      let a = Option.get (nextinit ()) in
                      let r = Tree.l a in
                      Check.complex (Some r);
                      if r.op <> OCONST then ignore (diag (Some r) "initializer subscript must be constant");
                      e := Int64.to_int r.vconst;
                      if t.width <> 0 && (!e < 0 || !e * w >= t.width) then ignore (diag (Some a) "initialization index out of range: %d" !e);
                      false
                    end
                  end
                  else false
                in
                if not stop then begin
                  let so = !e * w in
                  if so > !mw then mw := so;
                  if not (t.width <> 0 && !mw >= t.width) then begin
                    l := newlist !l (init1 s (link t) (o + so) true);
                    incr e;
                    go ()
                  end
                end
          in
          go ();
          if t.width = 0 then t.width <- !mw + w;
          !l
        end
      end
      else if typesu (e) then begin
        if isstruct a t then single ()
        else begin
          if t.width <= 0 then ignore (diag None "incomplete structure: %s" s.name);
          let l = ref None in
          let rec again () =
            let rec els (t1 : typ option) (a : node option) =
              match t1, a with
              | Some t1, Some a ->
                  if a.op = OARRAY && t1.etype <> Tarray then Some a
                  else if a.op = OELEM && (match t1.tsym, a.nsym with Some x, Some y -> x != y | _ -> true) then els t1.down (Some a)
                  else begin
                    if a.op = OELEM then ignore (nextinit ());
                    l := newlist !l (init1 s t1 (o + t1.offset) true);
                    match peekinit () with
                    | None -> None
                    | Some a when a.op = OELEM -> again ()
                    | a -> els t1.down a
                  end
              | _, a -> a
            in
            els t.link (peekinit ())
          in
          (match again () with Some a when a.op = OELEM -> ignore (diag (Some a) "structure element not found") | _ -> ());
          !l
        end
      end
      else diag None "unknown type in initialization: %s" (show_type (Some t))

let rec symadjust (s : sym) (n : node) del =
  match n.op with
  | ONAME -> if n.nsym == Some s || (match n.nsym with Some x -> x == s | None -> false) then n.xoffset <- n.xoffset - del
  | OCONST | OSTRING | OLSTRING | OINDREG | OREGISTER -> ()
  | _ -> Option.iter (fun l -> symadjust s l del) n.left; Option.iter (fun r -> symadjust s r del) n.right

(* an automatic array's initialization: zeroed first when partial
 * (dcl.c's contig) *)
let contig (s : sym) (n : node option) v =
  match n with
  | None -> None
  | Some nn ->
      let w = (Option.get s.typ).width in
      if v <> w then begin
        if v <> 0 then ignore (diag n "automatic adjustable array: %s" s.name);
        let v = s.soffset in
        autoffset := align !autoffset (Option.get s.typ) Aaut3;
        s.soffset <- - !autoffset;
        stkoff := maxround !stkoff !autoffset;
        symadjust s nn (v - s.soffset)
      end;
      let pw = ewidth Tind in
      if w <= pw || nn.op = OLIST || (nn.op = OASI && (match (Tree.l nn).ntype with Some lt -> lt.width = w | None -> false)) then n
      else begin
        let w = ref w in
        while !w land (pw - 1) <> 0 do incr w done;
        let rec name (q : node) = if q.op = ONAME then q else name (Tree.l q) in
        let q = name nn in
        let zt = if ewidth Tind > ewidth Tlong then ty Tvlong else ty Tlong in
        let p = dup q in
        p.ntype <- Some (typ Tind (Some zt)); p.xoffset <- s.soffset;
        let r = node OPOSTDEC (Some (dup p)) None in
        let q1 = node OIND (Some (dup p)) None in
        let m0 = node OCONST None None in m0.vconst <- 0L; m0.ntype <- Some zt;
        let r = node OLIST (Some r) (Some (node OAS (Some q1) (Some m0))) in
        let r = node ODWHILE (Some (dup p)) (Some r) in
        let q2 = dup p in
        q2.ntype <- (Tree.t q2).link; q2.xoffset <- q2.xoffset + !w;
        let q2 = node OADDR (Some q2) None in
        let q2 = node OASI (Some p) (Some q2) in
        Some (node OLIST (Some (node OLIST (Some q2) (Some r))) n)
      end
