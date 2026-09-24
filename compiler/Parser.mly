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

let bin o a b = mk (Binary (o, a, b))
let un o a = mk (Unary (o, a))
let asg o a b = mk (Assign (o, a, b))
let cnst et v = const_node (ty et) v

(* the declarator d, with the type and class of the words before it *)
let dcl f d = Declare.dodecl f !Declare.lastclass (Option.get !Declare.lasttype) d

let typed (t : typ) d = ignore (Declare.dodecl None Cxxx t d); Option.get !Declare.lastdcl

(* a name used: a local static's own symbol *)
let use (s : sym) =
  let s = if s.sclass = Clocal then Declare.mkstatic s else s in
  s.aused <- true;
  s

let string_node et len e =
  let t = typ Tarray (Some (ty et)) in
  t.width <- len;
  mk ~t e

(* a string continued by the next *)
let concat (x : expr) s =
  x.t.width <- x.t.width + String.length s;
  { x with e = (match x.e with Str a -> Str (a ^ s) | Lstr a -> Lstr (a ^ s) | e -> e) }

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

(* a block's volatiles, USED at its end *)
let with_used used (s : stmt) = match used with [] -> s | _ -> Block [ Used used; s ]

let body = Option.value ~default:(Block [])
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
  zctlist SEMI                          { ignore (dcl (Some Declare.xdecl) Dnone) }
| zctlist xdlist SEMI                   { () }
| fnparams block                        { !Declare.on_function $1 (with_used (Declare.revertdcl ()) $2) }
;

/* int f(a, b) int a; {: the parameters' offsets, in two passes */
fnhead:
  zctlist xdecor
    { Declare.lastdcl := None;
      Declare.firstarg := None;
      let s = dcl (Some Declare.xdecl) $2 in
      (match !Declare.lastdcl with
       | Some t when t.etype = Tfunc -> ()
       | _ -> ignore (diag None "not a function"));
      Declare.thisfn := !Declare.lastdcl;
      Declare.markdcl ();
      Declare.argmark $2 ~declared:false;
      Option.get s, $2 }
;
fnparams:
  fnhead pdecl                          { Declare.argmark (snd $1) ~declared:true; fst $1 }
;

xdlist:
  xdnamed                               { () }
| xdnamed ASSIGN init                   { let s = Option.get $1 in ignore (Declare.doinit s s.typ 0 $3) }
| xdlist COMMA xdlist                   { () }
;
xdnamed:
  xdecor                                { dcl (Some Declare.xdecl) $1 }
;

xdecor:
  xdecor2                               { $1 }
| STAR zgnlist xdecor                   { Dptr (Declare.simpleg $2, $3) }
;
xdecor2:
  ltag                                  { Dname $1 }
| LPAREN xdecor RPAREN                  { $2 }
| xdecor2 LPAREN zarglist RPAREN        { Dfunc ($1, $3) }
| xdecor2 LBRACK zexpr RBRACK           { Darray ($1, $3) }
;

/*****************************************************************************/
/* Automatic, parameter, and structure element declarations */
/*****************************************************************************/

adecl:
  ctlist SEMI                           { ignore (dcl (Some Declare.adecl) Dnone); [] }
| ctlist adlist SEMI                    { $2 }
;
adlist:
  adnamed                               { [] }
| adnamed ASSIGN init
    { let s = Option.get $1 in
      let w = (Option.get s.typ).width in
      Declare.contig s (Declare.doinit s s.typ 0 $3) w }
| adlist COMMA adlist                   { $1 @ $3 }
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
| ltag COLON lexpr                      { Dbit (Dname $1, $3) }
| COLON lexpr                           { Dbit (Dnone, $2) }
;

/*****************************************************************************/
/* Abstract declarators, initializers, parameters */
/*****************************************************************************/

abdecor:
  /* empty */                           { Dnone }
| abdecor1                              { $1 }
;
abdecor1:
  STAR zgnlist                          { Dptr (Declare.simpleg $2, Dnone) }
| STAR zgnlist abdecor1                 { Dptr (Declare.simpleg $2, $3) }
| abdecor2                              { $1 }
;
abdecor2:
  abdecor3                              { $1 }
| abdecor2 LPAREN zarglist RPAREN       { Dfunc ($1, $3) }
| abdecor2 LBRACK zexpr RBRACK          { Darray ($1, $3) }
;
abdecor3:
  LPAREN RPAREN                         { Dfunc (Dnone, []) }
| LBRACK zexpr RBRACK                   { Darray (Dnone, $2) }
| LPAREN abdecor1 RPAREN                { $2 }
;

init:
  expr                                  { Iexpr $1 }
| LBRACE ilist RBRACE                   { Ilist $2 }
;
qual:
  LBRACK lexpr RBRACK                   { Iindex $2 }
| DOT ltag                              { Ielem $2 }
| qual ASSIGN                           { $1 }
;
qlist:
  init COMMA                            { [ $1 ] }
| qlist init COMMA                      { $1 @ [ $2 ] }
| qual                                  { [ $1 ] }
| qlist qual                            { $1 @ [ $2 ] }
;
ilist:
  qlist                                 { $1 }
| init                                  { [ $1 ] }
| qlist init                            { $1 @ [ $2 ] }
;

zarglist:
  /* empty */                           { [] }
| arglist                               { $1 }
;
arglist:
  name                                  { [ Pname $1 ] }
| tlist abdecor                         { [ Proto ($1, $2) ] }
| tlist xdecor                          { [ Proto ($1, $2) ] }
| LDOTS                                 { [ Pdots ] }
| arglist COMMA arglist                 { $1 @ $3 }
;

/*****************************************************************************/
/* Statements */
/*****************************************************************************/

/* the statements, the last first */
block:
  LBRACE slist RBRACE                   { Block (List.rev $2) }
;
slist:
  /* empty */                           { [] }
| slist adecl                           { List.rev_append $2 $1 }
| slist stmnt                           { match $2 with Some s -> s :: $1 | None -> $1 }
;

labels:
  label                                 { [ $1 ] }
| labels label                          { $1 @ [ $2 ] }
;
label:
  LCASE expr COLON                      { Case (Some $2) }
| LDEFAULT COLON                        { Case None }
| LNAME COLON                           { Label (Declare.dcllabel $1 true) }
;

/* None: the empty statement, which makes no else */
stmnt:
  ulstmnt                               { $1 }
| labels ulstmnt                        { Some (Block ($1 @ Option.to_list $2)) }
;

forexpr:
  zcexpr                                { match $1 with Some e -> Expr e | None -> Block [] }
| ctlist adlist                         { Block $2 }
;

/* a block's declarations are undone at its end */
mark:
  /* empty */                           { Declare.markdcl () }
;

ulstmnt:
  zcexpr SEMI                           { Option.map (fun e -> Expr e) $1 }
| mark block                            { Some (with_used (Declare.revertdcl ()) $2) }
| LIF LPAREN cexpr RPAREN stmnt %prec LOWER_THAN_ELSE { Some (If ($3, body $5, None)) }
| LIF LPAREN cexpr RPAREN stmnt LELSE stmnt { Some (If ($3, body $5, $7)) }
| mark LFOR LPAREN forexpr SEMI zcexpr SEMI zcexpr RPAREN stmnt
    { let init = with_used (Declare.revertdcl ()) $4 in
      Some (For (init, $6, (match $8 with Some e -> Expr e | None -> Block []), body $10)) }
| LWHILE LPAREN cexpr RPAREN stmnt      { Some (While ($3, body $5)) }
| LDO stmnt LWHILE LPAREN cexpr RPAREN SEMI { Some (Dowhile (body $2, $5)) }
| LRETURN zcexpr SEMI                   { Some (Return ($2, link (Option.get !Declare.thisfn))) }
| LSWITCH LPAREN cexpr RPAREN stmnt
    { (* claude: 0-(0-e), as cc.y: the switch's value, converted as an int *)
      Some (Switch (bin Sub (cnst Tint 0L) (bin Sub (cnst Tint 0L) $3), body $5)) }
| LBREAK SEMI                           { Some Break }
| LCONTINUE SEMI                        { Some Continue }
| LGOTO ltag SEMI                       { Some (Goto (Declare.dcllabel $2 false)) }
| LUSED LPAREN zelist RPAREN SEMI       { Some (Used $3) }
| LSET LPAREN zelist RPAREN SEMI        { Some (Set $3) }
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
  expr                                  { mk ~t:(ty Tlong) (Unary (Cast, $1)) }
;
cexpr:
  expr                                  { $1 }
| cexpr COMMA cexpr                     { bin Comma $1 $3 }
;

expr:
  xuexpr                                { $1 }
| expr STAR expr                        { bin Mul $1 $3 }
| expr SLASH expr                       { bin Div $1 $3 }
| expr PERCENT expr                     { bin Mod $1 $3 }
| expr PLUS expr                        { bin Add $1 $3 }
| expr MINUS expr                       { bin Sub $1 $3 }
| expr LRSH expr                        { bin Ashr $1 $3 }
| expr LLSH expr                        { bin Ashl $1 $3 }
| expr LT expr                          { bin Lt $1 $3 }
| expr GT expr                          { bin Gt $1 $3 }
| expr LLE expr                         { bin Le $1 $3 }
| expr LGE expr                         { bin Ge $1 $3 }
| expr LEQ expr                         { bin Eq $1 $3 }
| expr LNE expr                         { bin Ne $1 $3 }
| expr AND expr                         { bin And $1 $3 }
| expr XOR expr                         { bin Xor $1 $3 }
| expr OR expr                          { bin Or $1 $3 }
| expr LANDAND expr                     { bin Andand $1 $3 }
| expr LOROR expr                       { bin Oror $1 $3 }
| expr QUESTION cexpr COLON expr        { mk (Cond ($1, $3, $5)) }
| expr ASSIGN expr                      { asg None $1 $3 }
| expr LPE expr                         { asg (Some Add) $1 $3 }
| expr LME expr                         { asg (Some Sub) $1 $3 }
| expr LMLE expr                        { asg (Some Mul) $1 $3 }
| expr LDVE expr                        { asg (Some Div) $1 $3 }
| expr LMDE expr                        { asg (Some Mod) $1 $3 }
| expr LLSHE expr                       { asg (Some Ashl) $1 $3 }
| expr LRSHE expr                       { asg (Some Ashr) $1 $3 }
| expr LANDE expr                       { asg (Some And) $1 $3 }
| expr LXORE expr                       { asg (Some Xor) $1 $3 }
| expr LORE expr                        { asg (Some Or) $1 $3 }
;

xuexpr:
  uexpr                                 { $1 }
| LPAREN tlist abdecor RPAREN xuexpr    { mk ~t:(typed $2 $3) (Unary (Cast, $5)) }
| LPAREN tlist abdecor RPAREN LBRACE ilist RBRACE { diag None "structure constructors are not in the subset" }
;

uexpr:
  pexpr                                 { $1 }
| STAR xuexpr                           { un Ind $2 }
| AND xuexpr                            { un Addr $2 }
| PLUS xuexpr                           { un Pos $2 }
| MINUS xuexpr                          { un Neg $2 }
| NOT xuexpr                            { un Not $2 }
| TILDE xuexpr                          { un Com $2 }
| LPP xuexpr                            { un Preinc $2 }
| LMM xuexpr                            { un Predec $2 }
| LSIZEOF uexpr                         { mk (Sizeof $2) }
| LSIGNOF uexpr                         { diag None "signof is not in the subset" }
;

pexpr:
  LPAREN cexpr RPAREN                   { $2 }
| LSIZEOF LPAREN tlist abdecor RPAREN   { mk (Sizeof_type (typed $3 $4)) }
| LSIGNOF LPAREN tlist abdecor RPAREN   { diag None "signof is not in the subset" }
| pexpr LPAREN zelist RPAREN
    { (* an undeclared function: int f() *)
      let f =
        match $1.e with
        | Name (s, _, _) when $1.t == untyped ->
            (match Declare.dodecl (Some Declare.xdecl) Cxxx (ty Tint) (Dfunc (Dname s, [])) with Some s -> name_node s | None -> $1)
        | _ -> $1
      in
      mk (Call (f, $3)) }
| pexpr LBRACK cexpr RBRACK             { un Ind (bin Add $1 $3) }
| pexpr LMG ltag                        { mk (Elem (un Ind $1, $3)) }
| pexpr DOT ltag                        { mk (Elem ($1, $3)) }
| pexpr LPP                             { un Postinc $1 }
| pexpr LMM                             { un Postdec $1 }
| name                                  { name_node $1 }
| LCONST                                { cnst (snd $1) (fst $1) }
| LFCONST                               { mk ~t:(ty (snd $1)) (Fconst (fst $1)) }
| string                                { $1 }
| lstring                               { $1 }
;

string:
  LSTRING                               { string_node Tchar (String.length $1 + 1) (Str $1) }
| string LSTRING                        { concat $1 $2 }
;
lstring:
  LLSTRING                              { string_node Tuint (String.length $1 + 4) (Lstr $1) }
| lstring LLSTRING                      { concat $1 $2 }
;

zelist:
  /* empty */                           { [] }
| elist                                 { $1 }
;
elist:
  expr                                  { [ $1 ] }
| elist COMMA elist                     { $1 @ $3 }
;

/*****************************************************************************/
/* Types */
/*****************************************************************************/

/* a structure's body, parsed in a state of its own */
sbody:
  sbody_open edecl RBRACE
    { let body = Declare.chain (List.rev !Declare.elems) in
      let e, t, c = $1 in
      Declare.elems := e; Declare.lasttype := t; Declare.lastclass := c;
      body }
;
sbody_open:
  LBRACE
    { let saved = !Declare.elems, !Declare.lasttype, !Declare.lastclass in
      Declare.elems := []; Declare.lastclass := Cxxx; Declare.lasttype := None;
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
    { if List.exists (fun w -> List.mem w Declare.type_words) $2 then ignore (diag None "duplicate types given: %s" (show_type (Some $1)));
      Declare.garbt $1 $2, Declare.simplec $2 }
| tname gctnlist                        { Declare.garbt (Declare.simplet ($1 @ $2)) $2, Declare.simplec $2 }
| gcnlist complex zgnlist               { Declare.garbt $2 ($1 @ $3), Declare.simplec $1 }
| gcnlist tname                         { Declare.garbt (Declare.simplet $2) $1, Declare.simplec $1 }
| gcnlist tname gctnlist                { Declare.garbt (Declare.simplet ($2 @ $3)) ($1 @ $3), Declare.simplec ($1 @ $3) }
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
| gctnlist gctname                      { $1 @ $2 }
;
zgnlist:
  /* empty */                           { [] }
| zgnlist gname                         { $1 @ $2 }
;
gctname:
  tname                                 { $1 }
| gname                                 { $1 }
| cname                                 { $1 }
;
gcnlist:
  gcname                                { $1 }
| gcnlist gcname                        { $1 @ $2 }
;
gcname:
  gname                                 { $1 }
| cname                                 { $1 }
;

tname:
  LCHAR { [ Declare.Char ] } | LSHORT { [ Declare.Short ] } | LINT { [ Declare.Int ] } | LLONG { [ Declare.Long ] }
| LSIGNED { [ Declare.Signed ] } | LUNSIGNED { [ Declare.Unsigned ] } | LFLOAT { [ Declare.Float ] }
| LDOUBLE { [ Declare.Double ] } | LVOID { [ Declare.Void ] }
;
cname:
  LAUTO { [ Declare.Auto ] } | LSTATIC { [ Declare.Static ] } | LEXTERN { [ Declare.Extern ] }
| LTYPEDEF { [ Declare.Typedef ] } | LTYPESTR { [ Declare.Typestr ] } | LREGISTER { [ Declare.Register ] } | LINLINE { [] }
;
gname:
  LCONSTNT { [ Declare.Const ] } | LVOLATILE { [ Declare.Volatile ] } | LRESTRICT { [] }
;

name:
  LNAME                                 { use $1 }
;
ltag:
  LNAME                                 { $1 }
| LTYPE                                 { $1 }
;
