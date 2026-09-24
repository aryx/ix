%{
(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* C's grammar, and the actions that declare as they parse: cc.y's, whose
 * mid-rule actions are small rules here (ocamlyacc has none).
 *
 * References: S. C. Johnson, "YACC -- Yet Another Compiler Compiler"
 * (UNIX Programmer's Manual, Seventh Ed., Vol. 2A, 1979), which
 * Thompson cites for 5c's first pass ("Plan 9 C Compilers", section
 * "Parsing"): declarations are
 * "interpreted immediately, building a block structured symbol table",
 * while "Executable statements are put into a parse tree" to be
 * compiled at the function's end. *)
open Tree

let nw op l r = Some (node op l r)

let cnst et v = let n = node OCONST None None in n.ntype <- Some (ty et); n.vconst <- v; n

(* the declarator n, with the type and class of the words before it *)
let dcl f n = Declare.dodecl f !Declare.lastclass (Option.get !Declare.lasttype) n

let typed (t : typ) n = ignore (Declare.dodecl None Cxxx t n); !Declare.lastdcl

(* a name: a use (mkstatic, aused) or a declarator's (tag) *)
let name_node (s : sym) =
  let n = node ONAME None None in
  n.nsym <- Some s; n.ntype <- s.typ; n.xoffset <- s.soffset; n.nclass <- s.sclass;
  
  n

let name s =
  let s = if s.sclass = Clocal then Declare.mkstatic s else s in
  s.aused <- true;
  name_node s

let string_node op et len s =
  let n = node op None None in
  let t = typ Tarray (Some (ty et)) in
  t.width <- len;
  n.ntype <- Some t; n.cstring <- s; n.nsym <- Some (lookup ".string"); n.nclass <- Cstatic;
  n

(* struct, union: a tag's body *)
let sudef (t : typ) body =
  t.link <- body;
  Declare.sualign t;
  t

(* struct { ... }: a tag of its own, _1_ *)
let anonymous et =
  incr Declare.taggen;
  Declare.dotag (lookup (Printf.sprintf "_%d_" !Declare.taggen)) et !Declare.autobn

let redeclared (s : sym) = match s.suetag with Some { link = Some _; _ } -> ignore (diag None "redeclare tag: %s" s.name) | _ -> ()
%}

%token <Tree.sym> LNAME LTYPE
%token <int64 * Tree.etype> LCONST
%token <float * Tree.etype> LFCONST
%token <string> LSTRING
%token <string> LLSTRING
%token LAUTO LBREAK LCASE LCHAR LCONTINUE LDEFAULT LDO LDOUBLE LELSE LEXTERN LFLOAT LFOR LGOTO
%token LIF LINT LLONG LREGISTER LRETURN LSHORT LSIZEOF LUSED LSTATIC LSTRUCT LSWITCH LTYPEDEF
%token LTYPESTR LUNION LUNSIGNED LWHILE LVOID LENUM LSIGNED LCONSTNT LVOLATILE LSET LSIGNOF
%token LRESTRICT LINLINE
%token LPE LME LMLE LDVE LMDE LRSHE LLSHE LANDE LXORE LORE LOROR LANDAND LEQ LNE LLE LGE
%token LLSH LRSH LMM LPP LMG LDOTS
%token SEMI COMMA ASSIGN QUESTION COLON OR XOR AND LT GT PLUS MINUS STAR SLASH PERCENT
%token LPAREN RPAREN LBRACK RBRACK LBRACE RBRACE DOT NOT TILDE EOF

%nonassoc LOWER_THAN_ELSE
%nonassoc LELSE
%left SEMI
%left COMMA
%right ASSIGN LPE LME LMLE LDVE LMDE LRSHE LLSHE LANDE LXORE LORE
%right QUESTION COLON
%left LOROR
%left LANDAND
%left OR
%left XOR
%left AND
%left LEQ LNE
%left LT GT LLE LGE
%left LLSH LRSH
%left PLUS MINUS
%left STAR SLASH PERCENT
%right LMM LPP LMG DOT LBRACK LPAREN

%start prog
%type <unit> prog

%%

prog:
  xdecls EOF                            { () }
;
xdecls:
  /* empty */                           { () }
| xdecls xdecl                          { () }
;

/*****************************************************************************/
/* External declarations */
/*****************************************************************************/

xdecl:
  zctlist SEMI                          { ignore (dcl (Some Declare.xdecl) None) }
| zctlist xdlist SEMI                   { () }
| fnparams block
    { let body = match Declare.revertdcl () with Some n -> Some (node OLIST (Some n) $2) | None -> $2 in
      !Declare.on_function $1 (Option.get body) }
;

/* int f(a, b) int a; {: the parameters' offsets, in two passes */
fnhead:
  zctlist xdecor
    { Declare.lastdcl := None;
      Declare.firstarg := None;
      ignore (dcl (Some Declare.xdecl) $2);
      (match !Declare.lastdcl with
       | Some t when t.etype = Tfunc -> ()
       | _ -> ignore (diag $2 "not a function"));
      Declare.thisfn := !Declare.lastdcl;
      Declare.markdcl ();
      let n = Option.get $2 in
      Declare.argmark n 0;
      n }
;
fnparams:
  fnhead pdecl                          { Declare.argmark $1 1; $1 }
;

xdlist:
  xdnamed                               { () }
| xdnamed ASSIGN init                   { let n = Option.get $1 in ignore (Declare.doinit (sym n) n.ntype 0 (Option.get $3)) }
| xdlist COMMA xdlist                   { () }
;
xdnamed:
  xdecor                                { dcl (Some Declare.xdecl) $1 }
;

xdecor:
  xdecor2                               { $1 }
| STAR zgnlist xdecor                   { let n = node OIND $3 None in n.ngarb <- Declare.simpleg $2; Some n }
;
xdecor2:
  tag                                   { Some $1 }
| LPAREN xdecor RPAREN                  { $2 }
| xdecor2 LPAREN zarglist RPAREN        { nw OFUNC $1 $3 }
| xdecor2 LBRACK zexpr RBRACK           { nw OARRAY $1 $3 }
;

/*****************************************************************************/
/* Automatic, parameter, and structure element declarations */
/*****************************************************************************/

adecl:
  ctlist SEMI                           { dcl (Some Declare.adecl) None }
| ctlist adlist SEMI                    { $2 }
;
adlist:
  adnamed                               { None }
| adnamed ASSIGN init
    { let n = Option.get $1 in
      let s = sym n in
      let w = (Option.get s.typ).width in
      Declare.contig s (Declare.doinit s n.ntype 0 (Option.get $3)) w }
| adlist COMMA adlist                   { match $1, $3 with _, None -> $1 | None, _ -> $3 | _ -> nw OLIST $1 $3 }
;
adnamed:
  xdecor                                { dcl (Some Declare.adecl) $1 }
;

pdecl:
  /* empty */                           { () }
| pdecl ctlist pdlist SEMI              { () }
;
pdlist:
  xdecor                                { ignore (dcl (Some Declare.pdecl) $1) }
| pdlist COMMA pdlist                   { () }
;

edecl:
  etlist zedlist SEMI                   { () }
| edecl etlist zedlist SEMI             { () }
;
etlist:
  tlist                                 { Declare.lasttype := Some $1 }
;
zedlist:
  /* empty */                           { Declare.lastfield := 0; Declare.edecl Cxxx (Option.get !Declare.lasttype) None }
| edlist                                { () }
;
edlist:
  edecor                                { ignore (Declare.dodecl (Some Declare.edecl) Cxxx (Option.get !Declare.lasttype) $1) }
| edlist COMMA edlist                   { () }
;
edecor:
  xdecor                                { $1 }
| tag COLON lexpr                       { nw OBIT (Some $1) (Some $3) }
| COLON lexpr                           { nw OBIT None (Some $2) }
;

/*****************************************************************************/
/* Abstract declarators, initializers, parameters */
/*****************************************************************************/

abdecor:
  /* empty */                           { None }
| abdecor1                              { $1 }
;
abdecor1:
  STAR zgnlist                          { let n = node OIND None None in n.ngarb <- Declare.simpleg $2; Some n }
| STAR zgnlist abdecor1                 { let n = node OIND $3 None in n.ngarb <- Declare.simpleg $2; Some n }
| abdecor2                              { $1 }
;
abdecor2:
  abdecor3                              { $1 }
| abdecor2 LPAREN zarglist RPAREN       { nw OFUNC $1 $3 }
| abdecor2 LBRACK zexpr RBRACK          { nw OARRAY $1 $3 }
;
abdecor3:
  LPAREN RPAREN                         { nw OFUNC None None }
| LBRACK zexpr RBRACK                   { nw OARRAY None $2 }
| LPAREN abdecor1 RPAREN                { $2 }
;

init:
  expr                                  { Some $1 }
| LBRACE ilist RBRACE                   { nw OINIT (Check.invert $2) None }
;
qual:
  LBRACK lexpr RBRACK                   { nw OARRAY (Some $2) None }
| DOT ltag                              { let n = node OELEM None None in n.nsym <- Some $2; Some n }
| qual ASSIGN                           { $1 }
;
qlist:
  init COMMA                            { $1 }
| qlist init COMMA                      { nw OLIST $1 $2 }
| qual                                  { $1 }
| qlist qual                            { nw OLIST $1 $2 }
;
ilist:
  qlist                                 { $1 }
| init                                  { $1 }
| qlist init                            { nw OLIST $1 $2 }
;

zarglist:
  /* empty */                           { None }
| arglist                               { Check.invert (Some $1) }
;
arglist:
  name                                  { $1 }
| tlist abdecor                         { let n = node OPROTO $2 None in n.ntype <- Some $1; n }
| tlist xdecor                          { let n = node OPROTO $2 None in n.ntype <- Some $1; n }
| LDOTS                                 { node ODOTDOT None None }
| arglist COMMA arglist                 { node OLIST (Some $1) (Some $3) }
;

/*****************************************************************************/
/* Statements */
/*****************************************************************************/

block:
  LBRACE slist RBRACE                   { match Check.invert $2 with None -> nw OLIST None None | b -> b }
;
slist:
  /* empty */                           { None }
| slist adecl                           { nw OLIST $1 $2 }
| slist stmnt                           { nw OLIST $1 $2 }
;

labels:
  label                                 { $1 }
| labels label                          { nw OLIST $1 $2 }
;
label:
  LCASE expr COLON                      { nw OCASE (Some $2) None }
| LDEFAULT COLON                        { nw OCASE None None }
| LNAME COLON                           { nw OLABEL (Some (Declare.dcllabel $1 true)) None }
;

stmnt:
  ulstmnt                               { $1 }
| labels ulstmnt                        { nw OLIST $1 $2 }
;

forexpr:
  zcexpr                                { $1 }
| ctlist adlist                         { $2 }
;

/* a block's declarations are undone at its end */
mark:
  /* empty */                           { Declare.markdcl () }
;

ulstmnt:
  zcexpr SEMI                           { $1 }
| mark block                            { match Declare.revertdcl () with Some n -> nw OLIST (Some n) $2 | None -> $2 }
| LIF LPAREN cexpr RPAREN stmnt %prec LOWER_THAN_ELSE { nw OIF (Some $3) (nw OLIST $5 None) }
| LIF LPAREN cexpr RPAREN stmnt LELSE stmnt { nw OIF (Some $3) (nw OLIST $5 $7) }
| mark LFOR LPAREN forexpr SEMI zcexpr SEMI zcexpr RPAREN stmnt
    { let init = match Declare.revertdcl () with Some n -> (match $4 with Some _ -> nw OLIST (Some n) $4 | None -> Some n) | None -> $4 in
      nw OFOR (nw OLIST $6 (nw OLIST init $8)) $10 }
| LWHILE LPAREN cexpr RPAREN stmnt      { nw OWHILE (Some $3) $5 }
| LDO stmnt LWHILE LPAREN cexpr RPAREN SEMI { nw ODWHILE (Some $5) $2 }
| LRETURN zcexpr SEMI                   { let n = node ORETURN $2 None in n.ntype <- (Option.get !Declare.thisfn).link; Some n }
| LSWITCH LPAREN cexpr RPAREN stmnt
    { (* claude: 0-(0-e), as cc.y: the switch's value, converted as an int *)
      let e = node OSUB (Some (cnst Tint 0L)) (Some $3) in
      let e = node OSUB (Some (cnst Tint 0L)) (Some e) in
      nw OSWITCH (Some e) $5 }
| LBREAK SEMI                           { nw OBREAK None None }
| LCONTINUE SEMI                        { nw OCONTINUE None None }
| LGOTO ltag SEMI                       { nw OGOTO (Some (Declare.dcllabel $2 false)) None }
| LUSED LPAREN zelist RPAREN SEMI       { nw OUSED $3 None }
| LSET LPAREN zelist RPAREN SEMI        { nw OSET $3 None }
;

/*****************************************************************************/
/* Expressions */
/*****************************************************************************/

zcexpr:
  /* empty */                           { None }
| cexpr                                 { Some $1 }
;
zexpr:
  /* empty */                           { None }
| lexpr                                 { Some $1 }
;
lexpr:
  expr                                  { let n = node OCAST (Some $1) None in n.ntype <- Some (ty Tlong); n }
;
cexpr:
  expr                                  { $1 }
| cexpr COMMA cexpr                     { node OCOMMA (Some $1) (Some $3) }
;

expr:
  xuexpr                                { $1 }
| expr STAR expr                        { node OMUL (Some $1) (Some $3) }
| expr SLASH expr                       { node ODIV (Some $1) (Some $3) }
| expr PERCENT expr                     { node OMOD (Some $1) (Some $3) }
| expr PLUS expr                        { node OADD (Some $1) (Some $3) }
| expr MINUS expr                       { node OSUB (Some $1) (Some $3) }
| expr LRSH expr                        { node OASHR (Some $1) (Some $3) }
| expr LLSH expr                        { node OASHL (Some $1) (Some $3) }
| expr LT expr                          { node OLT (Some $1) (Some $3) }
| expr GT expr                          { node OGT (Some $1) (Some $3) }
| expr LLE expr                         { node OLE (Some $1) (Some $3) }
| expr LGE expr                         { node OGE (Some $1) (Some $3) }
| expr LEQ expr                         { node OEQ (Some $1) (Some $3) }
| expr LNE expr                         { node ONE (Some $1) (Some $3) }
| expr AND expr                         { node OAND (Some $1) (Some $3) }
| expr XOR expr                         { node OXOR (Some $1) (Some $3) }
| expr OR expr                          { node OOR (Some $1) (Some $3) }
| expr LANDAND expr                     { node OANDAND (Some $1) (Some $3) }
| expr LOROR expr                       { node OOROR (Some $1) (Some $3) }
| expr QUESTION cexpr COLON expr        { node OCOND (Some $1) (nw OLIST (Some $3) (Some $5)) }
| expr ASSIGN expr                      { node OAS (Some $1) (Some $3) }
| expr LPE expr                         { node OASADD (Some $1) (Some $3) }
| expr LME expr                         { node OASSUB (Some $1) (Some $3) }
| expr LMLE expr                        { node OASMUL (Some $1) (Some $3) }
| expr LDVE expr                        { node OASDIV (Some $1) (Some $3) }
| expr LMDE expr                        { node OASMOD (Some $1) (Some $3) }
| expr LLSHE expr                       { node OASASHL (Some $1) (Some $3) }
| expr LRSHE expr                       { node OASASHR (Some $1) (Some $3) }
| expr LANDE expr                       { node OASAND (Some $1) (Some $3) }
| expr LXORE expr                       { node OASXOR (Some $1) (Some $3) }
| expr LORE expr                        { node OASOR (Some $1) (Some $3) }
;

xuexpr:
  uexpr                                 { $1 }
| LPAREN tlist abdecor RPAREN xuexpr
    { let n = node OCAST (Some $5) None in n.ntype <- typed $2 $3; n }
| LPAREN tlist abdecor RPAREN LBRACE ilist RBRACE
    { let n = node OSTRUCT $6 None in n.ntype <- typed $2 $3; n }
;

uexpr:
  pexpr                                 { $1 }
| STAR xuexpr                           { node OIND (Some $2) None }
| AND xuexpr                            { node OADDR (Some $2) None }
| PLUS xuexpr                           { node OPOS (Some $2) None }
| MINUS xuexpr                          { node ONEG (Some $2) None }
| NOT xuexpr                            { node ONOT (Some $2) None }
| TILDE xuexpr                          { node OCOM (Some $2) None }
| LPP xuexpr                            { node OPREINC (Some $2) None }
| LMM xuexpr                            { node OPREDEC (Some $2) None }
| LSIZEOF uexpr                         { node OSIZE (Some $2) None }
| LSIGNOF uexpr                         { node OSIGN (Some $2) None }
;

pexpr:
  LPAREN cexpr RPAREN                   { $2 }
| LSIZEOF LPAREN tlist abdecor RPAREN   { let n = node OSIZE None None in n.ntype <- typed $3 $4; n }
| LSIGNOF LPAREN tlist abdecor RPAREN   { let n = node OSIGN None None in n.ntype <- typed $3 $4; n }
| pexpr LPAREN zelist RPAREN
    { let n = node OFUNC (Some $1) None in
      (* an undeclared function: int f() *)
      if $1.op = ONAME && $1.ntype = None then ignore (Declare.dodecl (Some Declare.xdecl) Cxxx (ty Tint) (Some n));
      n.right <- Check.invert $3;
      n }
| pexpr LBRACK cexpr RBRACK             { node OIND (nw OADD (Some $1) (Some $3)) None }
| pexpr LMG ltag                        { let n = node ODOT (nw OIND (Some $1) None) None in n.nsym <- Some $3; n }
| pexpr DOT ltag                        { let n = node ODOT (Some $1) None in n.nsym <- Some $3; n }
| pexpr LPP                             { node OPOSTINC (Some $1) None }
| pexpr LMM                             { node OPOSTDEC (Some $1) None }
| name                                  { $1 }
| LCONST                                { cnst (snd $1) (fst $1) }
| LFCONST                               { let n = node OCONST None None in n.ntype <- Some (ty (snd $1)); n.fconst <- fst $1; n }
| string                                { $1 }
| lstring                               { $1 }
;

string:
  LSTRING                               { string_node OSTRING Tchar (String.length $1 + 1) $1 }
| string LSTRING                        { let t = Tree.t $1 in t.width <- t.width + String.length $2; $1.cstring <- $1.cstring ^ $2; $1 }
;
lstring:
  LLSTRING                              { string_node OLSTRING Tuint (String.length $1 + 4) $1 }
| lstring LLSTRING                      { let t = Tree.t $1 in t.width <- t.width + String.length $2; $1.cstring <- $1.cstring ^ $2; $1 }
;

zelist:
  /* empty */                           { None }
| elist                                 { Some $1 }
;
elist:
  expr                                  { $1 }
| elist COMMA elist                     { node OLIST (Some $1) (Some $3) }
;

/*****************************************************************************/
/* Types */
/*****************************************************************************/

/* a structure's body, parsed in a state of its own */
sbody:
  sbody_open edecl RBRACE
    { let body = !Declare.strf in
      let f, l, t, c = $1 in
      Declare.strf := f; Declare.strl := l; Declare.lasttype := t; Declare.lastclass := c;
      body }
;
sbody_open:
  LBRACE
    { let saved = !Declare.strf, !Declare.strl, !Declare.lasttype, !Declare.lastclass in
      Declare.strf := None; Declare.strl := None; Declare.lastclass := Cxxx; Declare.lasttype := None;
      saved }
;

zctlist:
  /* empty */                           { Declare.lastclass := Cxxx; Declare.lasttype := Some (ty Tint) }
| ctlist                                { () }
;

/* the words of a declaration: its type and class */
types:
  complex                               { $1, Cxxx }
| tname                                 { Declare.simplet $1, Cxxx }
| gcnlist                               { Declare.garbt (Declare.simplet $1) $1, Declare.simplec $1 }
| complex gctnlist
    { if $2 land lnot bclass land lnot bgarb <> 0 then ignore (diag None "duplicate types given: %s" (show_type (Some $1)));
      Declare.garbt $1 $2, Declare.simplec $2 }
| tname gctnlist                        { Declare.garbt (Declare.simplet (Declare.typebitor $1 $2)) $2, Declare.simplec $2 }
| gcnlist complex zgnlist               { Declare.garbt $2 ($1 lor $3), Declare.simplec $1 }
| gcnlist tname                         { Declare.garbt (Declare.simplet $2) $1, Declare.simplec $1 }
| gcnlist tname gctnlist                { Declare.garbt (Declare.simplet (Declare.typebitor $2 $3)) ($1 lor $3), Declare.simplec ($1 lor $3) }
;

tlist:
  types
    { let t, c = $1 in
      if c <> Cxxx then ignore (diag None "illegal combination of class 4: %s" (cname c));
      t }
;
ctlist:
  types                                 { let t, c = $1 in Declare.lasttype := Some t; Declare.lastclass := c }
;

complex:
  LSTRUCT ltag                          { Declare.dotag $2 Tstruct 0 }
| struct_tag sbody                      { redeclared $1; sudef (Option.get $1.suetag) $2 }
| LSTRUCT sbody                         { sudef (anonymous Tstruct) $2 }
| LUNION ltag                           { Declare.dotag $2 Tunion 0 }
| union_tag sbody                       { redeclared $1; sudef (Option.get $1.suetag) $2 }
| LUNION sbody                          { sudef (anonymous Tunion) $2 }
| LENUM ltag
    { let t = Declare.dotag $2 Tenum 0 in
      if t.link = None then t.link <- Some (ty Tint);
      Tree.link t }
| enum_tag enum_open enum RBRACE
    { let t = Option.get $1.suetag in
      if t.link <> None then ignore (diag None "redeclare tag: %s" $1.name);
      if !Declare.en_tenum = None then (ignore (diag None "enum type ambiguous: %s" $1.name));
      t.link <- !Declare.en_tenum;
      Option.get !Declare.en_tenum }
| LENUM enum_open enum RBRACE           { Option.get !Declare.en_tenum }
| LTYPE                                 { Option.get (Declare.tcopy $1.typ) }
;
struct_tag:
  LSTRUCT ltag                          { ignore (Declare.dotag $2 Tstruct !Declare.autobn); $2 }
;
union_tag:
  LUNION ltag                           { ignore (Declare.dotag $2 Tunion !Declare.autobn); $2 }
;
enum_tag:
  LENUM ltag                            { ignore (Declare.dotag $2 Tenum !Declare.autobn); $2 }
;
enum_open:
  LBRACE                                { Declare.en_tenum := None; Declare.en_cenum := None }
;
enum:
  LNAME                                 { Declare.doenum $1 None }
| LNAME ASSIGN expr                     { Declare.doenum $1 (Some $3) }
| enum COMMA                            { () }
| enum COMMA enum                       { () }
;

gctnlist:
  gctname                               { $1 }
| gctnlist gctname                      { Declare.typebitor $1 $2 }
;
zgnlist:
  /* empty */                           { 0 }
| zgnlist gname                         { Declare.typebitor $1 $2 }
;
gctname:
  tname                                 { $1 }
| gname                                 { $1 }
| cname                                 { $1 }
;
gcnlist:
  gcname                                { $1 }
| gcnlist gcname                        { Declare.typebitor $1 $2 }
;
gcname:
  gname                                 { $1 }
| cname                                 { $1 }
;

tname:
  LCHAR { b Tchar } | LSHORT { b Tshort } | LINT { b Tint } | LLONG { b Tlong } | LSIGNED { b Tsigned }
| LUNSIGNED { b Tunsigned } | LFLOAT { b Tfloat } | LDOUBLE { b Tdouble } | LVOID { b Tvoid }
;
cname:
  LAUTO { b Tauto } | LSTATIC { b Tstatic } | LEXTERN { b Textern } | LTYPEDEF { b Ttypedef }
| LTYPESTR { b Ttypestr } | LREGISTER { b Tregister } | LINLINE { 0 }
;
gname:
  LCONSTNT { b Tconstnt } | LVOLATILE { b Tvolatile } | LRESTRICT { 0 }
;

name:
  LNAME                                 { name $1 }
;
tag:
  ltag                                  { name_node $1 }
;
ltag:
  LNAME                                 { $1 }
| LTYPE                                 { $1 }
;
