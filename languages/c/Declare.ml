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

(* a function's name and its body, parsed: to the code generator *)
let on_function : (sym -> stmt -> unit) ref = ref (fun _ _ -> ())

(* the back end's, set by the command (CLI): an initializer's data (swt.c's gextern) *)
let gextern : (sym -> expr -> int -> int -> unit) ref = ref (fun _ _ _ _ -> ())

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
let elems : typ list ref = ref []      (* a structure's, the last first *)
let taggen = ref 0
let firstarg : sym option ref = ref None
let firstargtype : typ option ref = ref None
let thisfn : typ option ref = ref None
let en_tenum : typ option ref = ref None
let en_cenum : typ option ref = ref None
let en_lastenum = ref 0L
let en_floatenum = ref 0.

(* what the end of a block undoes, the last first: its mark, the
 * declarations its names hid, the tags; a function's labels at its end *)
type undo =
  | Mark of int * int                 (* the offset of the autos, the block *)
  | Hid of sym * typ option * cls * int * int * bool   (* its type, class, offset, block, used *)
  | Tag of sym * typ option * int

let dclstack : undo list ref = ref []
let labels : sym list ref = ref []

let push1 (s : sym) = dclstack := Hid (s, s.typ, s.sclass, s.soffset, s.block, s.aused) :: !dclstack

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

(* declare the name of d, whose type is around it: t of class c, given
 * to f (xdecl, adecl, pdecl, edecl; or none); the symbol declared *)
let rec dodecl (f : (cls -> typ -> sym option -> unit) option) c (t : typ) (d : decl) : sym option =
  nearln := !lineno;
  lastfield := 0;
  let rec loop (t : typ) = function
    | Dnone -> lastdcl := Some t; None
    | Darray (d, size) ->
        let t = typ Tarray (Some t) in
        t.width <- 0;
        Option.iter (fun n ->
          let n = Check.complex n in
          let v = match n.e with Const v -> Int64.to_int v | _ -> -1 in
          let v = if v <= 0 then (ignore (diag (Some n) "array size must be a positive constant"); 1) else v in
          t.width <- v * (link t).width) size;
        loop t d
    | Dptr (g, d) -> let t = typ Tind (Some t) in t.garb <- g; loop t d
    | Dfunc (d, ps) -> let t = typ Tfunc (Some t) in t.down <- fnproto ps; loop t d
    | Dbit _ -> diag None "bitfields are not in the subset"
    | Dname s ->
        let s = match f with None -> s | Some f -> f c t (Some s); if s.sclass = Clocal then mkstatic s else s in
        lastdcl := Some t;
        Some s
  in
  loop t d

(* whether the parameters have prototypes, and plain names *)
and anyproto (ps : param list) =
  List.exists (function Pname _ -> false | _ -> true) ps, List.exists (function Pname _ -> true | _ -> false) ps

(* the arguments' types, from a prototype (dcl.c's fnproto) *)
and fnproto (ps : param list) =
  match anyproto ps with
  | true, false -> protos ps
  | ansi, old -> if ansi && old then ignore (diag None "mixed ansi/old function declaration"); None

(* the parameters' types, chained by down *)
and protos (ps : param list) : typ option =
  match ps with
  | [] -> None
  | p :: rest ->
      let t =
        match p with
        | Proto (pt, d) ->
            lastdcl := None;
            ignore (dodecl None Cxxx pt d);
            (* a copy: the prototype's list is its own *)
            (match !lastdcl with Some ld -> copytyp (paramconv ld true) | None -> typ Txxx None)
        | Pname _ -> ignore (diag None "incomplete argument prototype"); typ Tint None
        | Pdots -> typ Tdot None
      in
      t.down <- protos rest;
      Some t

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
  t.tsym <- s;
  elems := t :: !elems

(* the elements, linked by down: a structure's body *)
let rec chain (ts : typ list) = match ts with [] -> None | t :: rest -> t.down <- chain rest; Some t

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

let doenum (s : sym) (n : expr option) =
  Option.iter (fun n ->
    let n = Check.complex n in
    en_cenum := Some n.t;
    en_tenum := maxtype !en_cenum !en_tenum;
    match n.e with
    | Const v -> en_lastenum := v
    | Fconst f -> en_floatenum := f
    | _ -> ignore (diag (Some n) "enum not a constant: %s" s.name)) n;
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
 * the bottom one, its labels); the volatiles, to be USED *)
let revertdcl () : expr list =
  let used = ref [] in
  let rec go () =
    match !dclstack with
    | [] -> ignore (diag None "pop off dcl stack")
    | u :: rest ->
        dclstack := rest;
        match u with
        | Mark (o, bn) ->
            autoffset := o; autobn := bn;
            if rest = [] then (List.iter (fun (s : sym) -> s.label <- None) !labels; labels := [])
        | Hid (s, t, c, o, bl, aused) ->
            (match s.typ with
             | Some tt when tt.garb land gvolatile <> 0 -> used := mk (Unary (Addr, name_node s)) :: !used
             | _ -> ());
            s.typ <- t; s.sclass <- c; s.soffset <- o; s.block <- bl; s.aused <- aused;
            go ()
        | Tag (s, t, bl) -> s.suetag <- t; s.sueblock <- bl; go ()
  in
  go ();
  !used

let rec decl_name = function
  | Dname s -> Some s
  | Dptr (_, d) | Dfunc (d, _) | Darray (d, _) | Dbit (d, _) -> decl_name d
  | Dnone -> None

(* the parameters: hidden, or once declared, given their offsets *)
let walkparam (ps : param list) ~declared =
  List.iter (function
    | Proto (t, Dnone) when t == ty Tvoid -> ()
    | Proto (t, d) -> (
        match decl_name d with
        | Some s -> if not declared then (push1 s; s.soffset <- -1) else ignore (dodecl (Some pdecl) Cparam t d)
        | None -> if declared then (ignore (dodecl None Cparam t d); pdecl Cparam (Option.get !lastdcl) None))
    | Pdots -> ()
    | Pname s ->
        if not declared then (push1 s; s.soffset <- -1)
        else if s.soffset <> -1 then param (Some s) (Option.get s.typ)
        else ignore (dodecl (Some pdecl) Cxxx (ty Tint) (Dname s))) ps

(* the parameters' offsets; ~declared, after their old-style declarations *)
let argmark (d : decl) ~declared =
  autoffset := align 0 (link (Option.get !thisfn)) Aarg0;
  stkoff := 0;
  (* the function's own: the parameters of the Dfunc around its name *)
  let rec go = function
    | Dfunc (Dname _, ps) ->
        walkparam ps ~declared;
        if declared && anyproto ps = (false, true) then ignore (diag None "old-style parameters are not in the subset")
    | Dptr (_, d) | Dfunc (d, _) | Darray (d, _) | Dbit (d, _) -> go d
    | Dname _ | Dnone -> ()
  in
  go d;
  autoffset := 0;
  stkoff := 0

(* a label, defined (f) or used, forgotten at the function's end
 * (dcl.c's dcllabel) *)
let dcllabel (s : sym) f =
  match s.label with
  | Some l ->
      if f then (if l.defined then ignore (diag None "label reused: %s" s.name); l.defined <- true);
      l
  | None ->
      labels := s :: !labels;
      let l = { lsym = s; defined = f; lpc = 0 } in
      s.label <- Some l;
      l

(*****************************************************************************)
(* Initializers (dcl.c's doinit, init1) *)
(*****************************************************************************)

(* what init1 takes from, the next first: the initializers; a string
 * spread over an array's elements; an expression typed already *)
type item = I of init | Chars of chars | Typed of expr
and chars = { mutable rest : string; mutable left : int; elt : typ; wide : bool }

let initlist : item list ref = ref []

let nextinit () : item option =
  match !initlist with
  | [] -> None
  | Chars c :: rest ->
      (* the string's next character, the NUL past its end *)
      let n = if c.wide then 4 else 1 in
      let v =
        if String.length c.rest < n then 0L
        else if c.wide then convvtox (Int64.of_int32 (String.get_int32_le c.rest 0)) Tuint
        else convvtox (Int64.of_int (Char.code c.rest.[0])) Tchar
      in
      if String.length c.rest >= n then c.rest <- String.sub c.rest n (String.length c.rest - n);
      c.left <- c.left - c.elt.width;
      if c.left <= 0 then initlist := rest;
      Some (I (Iexpr (const_node c.elt v)))
  | a :: rest -> initlist := rest; Some a

let rec doinit (s : sym) (t : typ option) o (a : init) : expr list = doitem s t o (I a)

and doitem (s : sym) (t : typ option) o (a : item) : expr list =
  match t with
  | None -> []
  | Some t ->
      if s.sclass = Cextern then s.sclass <- Cglobl;
      let saved = !initlist in
      initlist := (match a with I (Ilist l) -> List.map (fun i -> I i) l | a -> [ a ]);
      let r = init1 s t o false in
      (match !initlist with [] -> () | _ -> ignore (diag None "more initializers than structure: %s" s.name));
      initlist := saved;
      r

(* a structure initialized by an expression of its type (the expression
 * typed on the way, once) *)
and isstruct (t : typ) =
  match !initlist with
  | Typed n :: _ -> same n.t t
  | I (Iexpr ({ e = Str _ | Lstr _ | Const _ | Fconst _; _ })) :: _ -> false
  | I (Iexpr x) :: rest -> let n = Check.tcom x in initlist := Typed n :: rest; same n.t t
  | _ -> false

and init1 (s : sym) (t : typ) o exflag : expr list =
  match !initlist with
  | [] -> []
  | I (Ilist _) :: _ when exflag -> (match nextinit () with Some a -> doitem s (Some t) o a | None -> [])
  | a :: _ ->
      let single () =
        match a with
        | I (Iindex _ | Ielem _) -> []
        | _ -> (
            match nextinit () with
            | None -> []
            | Some it ->
                let a = match it with I (Iexpr a) -> a | Typed a -> mk ~t:a.t ~line:a.line (Typed a) | _ -> diag None "initializer is not an expression: %s" s.name in
                if s.sclass = Cauto then [ mk (Assign (None, name_of s t s.sclass (s.soffset + o), a)) ]
                else begin
                  let a = Check.complex a in
                  match a.e with
                  | Const _ | Fconst _ ->
                      if Check.vconst a <> 0 && t.etype = Tind && et a <> Tind then ignore (diag (Some a) "initialize pointer to an integer: %s" s.name);
                      let a = if same a.t t then a else Check.complex (mk ~t ~line:a.line (Unary (Cast, a))) in
                      if not (is_const a) then ignore (diag (Some a) "initializer is not a constant: %s" s.name);
                      if Check.vconst a <> 0 then !gextern s a o t.width;
                      []
                  | _ ->
                      let rec uncast (a : expr) = match a.e with Unary (Cast, x) -> uncast x | _ -> a in
                      let a = uncast a in
                      let addr = match a.e with Unary (Addr, x) -> Some x | _ -> None in
                      if t.etype = Tind then begin
                        if not (same t a.t) then ignore (diag (Some a) "initialization of incompatible pointers: %s" s.name);
                        !gextern s (Option.value addr ~default:a) o t.width; []
                      end
                      else match addr with Some x -> !gextern s x o t.width; [] | None -> diag (Some a) "initializer is not a constant: %s" s.name
                end)
      in
      let e = t.etype in
      if typei e || typefd e || e = Tind then single ()
      else if e = Tarray then begin
        let w = (link t).width in
        match a with
        | I (Iexpr ({ e = (Str chars | Lstr chars) as k; _ } as str)) when typei (link t).etype ->
            ignore (nextinit ());
            let mw = t.width / w and ew = (link str.t).width in
            let so = str.t.width / ew in
            if mw <> 0 && so > mw then begin
              if so <> mw + 1 then ignore (diag (Some str) "string initialization larger than array");
              str.t.width <- str.t.width - ew
            end;
            let wide = match k with Lstr _ -> true | _ -> false in
            doitem s (Some t) o (Chars { rest = chars; left = str.t.width; elt = link str.t; wide })
        | _ ->
            let mw = ref (- w) and l = ref [] and e = ref 0 in
            let rec go () =
              match !initlist with
              | [] -> ()
              | I (Ielem _) :: _ when (link t).etype <> Tstruct -> ()
              | a :: _ ->
                  let stop =
                    match a with
                    | I (Iindex _) when !e <> 0 && exflag -> true
                    | I (Iindex _) ->
                        let r = match nextinit () with Some (I (Iindex r)) -> Check.complex r | _ -> assert false in
                        (match r.e with Const v -> e := Int64.to_int v | _ -> ignore (diag (Some r) "initializer subscript must be constant"));
                        if t.width <> 0 && (!e < 0 || !e * w >= t.width) then ignore (diag (Some r) "initialization index out of range: %d" !e);
                        false
                    | _ -> false
                  in
                  if not stop then begin
                    let so = !e * w in
                    if so > !mw then mw := so;
                    if not (t.width <> 0 && !mw >= t.width) then begin
                      l := !l @ init1 s (link t) (o + so) true;
                      incr e;
                      go ()
                    end
                  end
            in
            go ();
            if t.width = 0 then t.width <- !mw + w;
            !l
      end
      else if typesu e then begin
        if isstruct t then single ()
        else begin
          if t.width <= 0 then ignore (diag None "incomplete structure: %s" s.name);
          let l = ref [] in
          (* the elements in order, or from the one a designator names *)
          let rec again () =
            let rec els (t1 : typ option) =
              match t1, !initlist with
              | Some t1, a :: _ ->
                  (match a with
                   | I (Iindex _) when t1.etype <> Tarray -> Some a
                   | I (Ielem m) when (match t1.tsym with Some x -> x != m | None -> true) -> els t1.down
                   | _ ->
                       (match a with I (Ielem _) -> ignore (nextinit ()) | _ -> ());
                       l := !l @ init1 s t1 (o + t1.offset) true;
                       match !initlist with
                       | [] -> None
                       | I (Ielem _) :: _ -> again ()
                       | _ -> els t1.down)
              | _, a :: _ -> Some a
              | _, [] -> None
            in
            els t.link
          in
          (match again () with Some (I (Ielem _)) -> ignore (diag None "structure element not found") | _ -> ());
          !l
        end
      end
      else diag None "unknown type in initialization: %s" (show_type (Some t))

let rec symadjust (s : sym) del (n : expr) : expr =
  let f = symadjust s del in
  match n.e with
  | Name (s', c, o) when s' == s -> { n with e = Name (s', c, o - del) }
  | Unary (o, a) -> { n with e = Unary (o, f a) }
  | Binary (o, a, b) -> { n with e = Binary (o, f a, f b) }
  | Assign (o, a, b) -> { n with e = Assign (o, f a, f b) }
  | Cond (a, b, c) -> { n with e = Cond (f a, f b, f c) }
  | Call (a, args) -> { n with e = Call (f a, List.map f args) }
  | Elem (a, m) -> { n with e = Elem (f a, m) }
  | Dot (a, o) -> { n with e = Dot (f a, o) }
  | Sizeof a -> { n with e = Sizeof (f a) }
  | _ -> n

(* an automatic array's initialization: zeroed first when partial
 * (dcl.c's contig) *)
let contig (s : sym) (inits : expr list) v : stmt list =
  match inits with
  | [] -> []
  | first :: _ ->
      let w = (Option.get s.typ).width in
      let inits =
        if v = w then inits
        else begin
          if v <> 0 then ignore (diag None "automatic adjustable array: %s" s.name);
          let v = s.soffset in
          autoffset := align !autoffset (Option.get s.typ) Aaut3;
          s.soffset <- - !autoffset;
          stkoff := maxround !stkoff !autoffset;
          List.map (symadjust s (v - s.soffset)) inits
        end
      in
      let pw = ewidth Tind in
      let all = List.map (fun e -> Expr e) inits in
      let covers = match inits with [ { e = Assign (_, l, _); _ } ] -> l.t.width = w | [ _ ] -> false | _ -> true in
      if w <= pw || covers then all
      else begin
        (* the array's first word a pointer past its end, down to it *)
        let w = ref w in
        while !w land (pw - 1) <> 0 do incr w done;
        let rec name (q : expr) = match q.e with Name _ -> q | Assign (_, a, _) | Unary (_, a) | Binary (_, a, _) -> name a | _ -> q in
        let q = name first in
        let zt = if ewidth Tind > ewidth Tlong then ty Tvlong else ty Tlong in
        let p = { q with t = typ Tind (Some zt); e = (match q.e with Name (s', c, _) -> Name (s', c, s.soffset) | e -> e) } in
        let clear = Dowhile (Block [ Expr (mk (Unary (Postdec, p))); Expr (mk (Assign (None, mk (Unary (Ind, p)), const_node zt 0L))) ], p) in
        let past = mk (Unary (Addr, plus { p with t = link p.t } !w)) in
        Expr (mk (Assign (None, p, past))) :: clear :: all
      end
