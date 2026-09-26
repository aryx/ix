/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* ocaml-light's grammar (its parsing/parser.mly, OCaml 1.07's), for the
 * subset: no objects, attributes, let-operators or lazy, which its
 * parser skips or accepts for xix's sake and mini-9pi doesn't use. The
 * precedences are OCaml's, so that ; is looser than if, a match inside
 * a match's clause takes the clauses after it, and f x :: l is
 * (f x) :: l. The sugar is undone here (Ast's comment). */
%{
open Ast

let loc () = (Parsing.symbol_start_pos ()).Lexing.pos_lnum
let mkexp e = { e; eloc = loc () }
let mkpat p = { p; ploc = loc () }
let mkitem i = { i; iloc = loc () }
let mksig s = { s; sloc = loc () }
let ident x = mkexp (Eident [ x ])
let infix a op b = mkexp (Eapply (ident op, [ a; b ]))
let unit () = mkexp (Econstruct ([ "()" ], None))

(* -e is ~-e, -1 the constant, -. the float's *)
let uminus op e =
  match op, e.e with
  | "-", Econst (Int n) -> mkexp (Econst (Int (-n)))
  | ("-" | "-."), Econst (Float f) -> mkexp (Econst (Float ("-" ^ f)))
  | _ -> mkexp (Eapply (ident ("~" ^ op), [ e ]))

let rec mklist = function
  | [] -> mkexp (Econstruct ([ "[]" ], None))
  | e :: l -> { e = Econstruct ([ "::" ], Some { e = Etuple [ e; mklist l ]; eloc = e.eloc }); eloc = e.eloc }

let rec mkpatlist = function
  | [] -> mkpat (Pconstruct ([ "[]" ], None))
  | p :: l -> { p = Pconstruct ([ "::" ], Some { p = Ptuple [ p; mkpatlist l ]; ploc = p.ploc }); ploc = p.ploc }

(* fun p q -> e: a function of p whose body is a function of q *)
let mkfun p e = mkexp (Efunction [ p, None, e ])

let array_op m f args = mkexp (Eapply (mkexp (Eident [ m; f ]), args))
%}

%token <int> INT
%token <char> CHAR
%token <string> FLOAT STRING LIDENT UIDENT
%token <string> PREFIXOP INFIXOP0 INFIXOP1 INFIXOP2 INFIXOP3 INFIXOP4 SUBTRACTIVE
%token AND AS ASSERT BEGIN DO DONE DOWNTO ELSE END EXCEPTION EXTERNAL FALSE FOR FUN FUNCTION IF IN LET MATCH
%token MODULE MUTABLE OF OPEN OR REC SIG STRUCT THEN TO TRUE TRY TYPE VAL WHEN WHILE WITH
%token LPAREN RPAREN LBRACE RBRACE LBRACKET RBRACKET LBRACKETBAR BARRBRACKET
%token AMPERSAND AMPERAMPER BAR BARBAR COLON COLONCOLON COLONEQUAL COMMA DOT DOTDOT EQUAL GREATER LESS
%token LESSMINUS MINUSGREATER QUOTE SEMI SEMISEMI STAR UNDERSCORE
%token EOF

/* from the loosest */
%right prec_let
%right prec_type_def
%right SEMI
%right prec_fun prec_match prec_try
%right prec_list
%right prec_if
%right COLONEQUAL LESSMINUS
%left AS
%left BAR
%left COMMA
%right prec_type_arrow
%right OR BARBAR
%right AMPERSAND AMPERAMPER
%left INFIXOP0 EQUAL LESS GREATER
%right INFIXOP1
%right COLONCOLON
%left INFIXOP2 SUBTRACTIVE
%left INFIXOP3 STAR
%right INFIXOP4
%right prec_unary_minus
%left prec_appl
%right prec_constr_appl
%left DOT
%right PREFIXOP

%start implementation interface
%type <Ast.structure> implementation
%type <Ast.signature> interface

%%

implementation:
  | structure EOF { $1 }
;
interface:
  | signature EOF { List.rev $1 }
;

/* modules */

structure:
  | structure_tail { $1 }
  | seq_expr structure_tail { mkitem (Ieval $1) :: $2 }
;
structure_tail:
  | /* empty */ { [] }
  | SEMISEMI { [] }
  | SEMISEMI seq_expr structure_tail { mkitem (Ieval $2) :: $3 }
  | SEMISEMI structure_item structure_tail { $2 :: $3 }
  | structure_item structure_tail { $1 :: $2 }
;
structure_item:
  | LET rec_flag let_bindings
      { match $3 with
        | [ ({ p = Pany; _ }, e) ] -> mkitem (Ieval e)
        | bs -> mkitem (Ivalue ($2, List.rev bs)) }
  | EXTERNAL val_ident COLON core_type EQUAL primitive_declaration { mkitem (Iexternal ($2, $4, $6)) }
  | TYPE type_declarations { mkitem (Itype (List.rev $2)) }
  | EXCEPTION UIDENT constructor_arguments { mkitem (Iexception ($2, $3)) }
  | MODULE UIDENT module_binding { mkitem (Imodule ($2, $3)) }
  | OPEN mod_longident { mkitem (Iopen $2) }
;
module_binding:
  | EQUAL module_expr { $2 }
  | COLON module_type EQUAL module_expr { Mconstraint ($4, $2) }
;
module_expr:
  | mod_longident { Mident $1 }
  | STRUCT structure END { Mstruct $2 }
  | LPAREN module_expr COLON module_type RPAREN { Mconstraint ($2, $4) }
  | LPAREN module_expr RPAREN { $2 }
;
signature:
  | /* empty */ { [] }
  | signature signature_item { $2 :: $1 }
  | signature signature_item SEMISEMI { $2 :: $1 }
;
signature_item:
  | VAL val_ident COLON core_type { mksig (Sval ($2, $4)) }
  | EXTERNAL val_ident COLON core_type EQUAL primitive_declaration { mksig (Sexternal ($2, $4, $6)) }
  | TYPE type_declarations { mksig (Stype (List.rev $2)) }
  | EXCEPTION UIDENT constructor_arguments { mksig (Sexception ($2, $3)) }
  | MODULE UIDENT COLON module_type { mksig (Smodule ($2, $4)) }
  | OPEN mod_longident { mksig (Sopen $2) }
;
module_type:
  | mod_longident { MTident $1 }
  | SIG signature END { MTsig (List.rev $2) }
  | LPAREN module_type RPAREN { $2 }
;

/* expressions */

seq_expr:
  | expr { $1 }
  | expr SEMI { $1 }
  | expr SEMI seq_expr { mkexp (Eseq ($1, $3)) }
;
expr:
  | simple_expr { $1 }
  | constr_longident simple_expr %prec prec_constr_appl { mkexp (Econstruct ($1, Some $2)) }
  | expr COLONCOLON expr { mkexp (Econstruct ([ "::" ], Some (mkexp (Etuple [ $1; $3 ])))) }
  | simple_expr DOT label_longident LESSMINUS expr { mkexp (Esetfield ($1, $3, $5)) }
  | expr_comma_list { mkexp (Etuple (List.rev $1)) }
  | FUNCTION opt_bar match_cases %prec prec_fun { mkexp (Efunction (List.rev $3)) }
  | FUN simple_pattern fun_def %prec prec_fun { mkfun $2 $3 }
  | simple_expr simple_expr_list %prec prec_appl { mkexp (Eapply ($1, List.rev $2)) }
  | LET rec_flag let_bindings IN seq_expr %prec prec_let { mkexp (Elet ($2, List.rev $3, $5)) }
  | expr INFIXOP0 expr { infix $1 $2 $3 }
  | expr INFIXOP1 expr { infix $1 $2 $3 }
  | expr INFIXOP2 expr { infix $1 $2 $3 }
  | expr INFIXOP3 expr { infix $1 $2 $3 }
  | expr INFIXOP4 expr { infix $1 $2 $3 }
  | expr SUBTRACTIVE expr { infix $1 $2 $3 }
  | expr STAR expr { infix $1 "*" $3 }
  | expr EQUAL expr { infix $1 "=" $3 }
  | expr LESS expr { infix $1 "<" $3 }
  | expr GREATER expr { infix $1 ">" $3 }
  | expr BARBAR expr { infix $1 "||" $3 }
  | expr OR expr { infix $1 "or" $3 }
  | expr AMPERAMPER expr { infix $1 "&&" $3 }
  | expr AMPERSAND expr { infix $1 "&" $3 }
  | expr COLONEQUAL expr { infix $1 ":=" $3 }
  | SUBTRACTIVE expr %prec prec_unary_minus { uminus $1 $2 }
  | MATCH seq_expr WITH opt_bar match_cases %prec prec_match { mkexp (Ematch ($2, List.rev $5)) }
  | TRY seq_expr WITH opt_bar match_cases %prec prec_try { mkexp (Etry ($2, List.rev $5)) }
  | IF seq_expr THEN expr ELSE expr %prec prec_if { mkexp (Eif ($2, $4, Some $6)) }
  | IF seq_expr THEN expr %prec prec_if { mkexp (Eif ($2, $4, None)) }
  | WHILE seq_expr DO seq_expr DONE { mkexp (Ewhile ($2, $4)) }
  | FOR val_ident EQUAL seq_expr direction_flag seq_expr DO seq_expr DONE { mkexp (Efor ($2, $4, $6, $5, $8)) }
  | simple_expr DOT LPAREN seq_expr RPAREN LESSMINUS expr { array_op "Array" "set" [ $1; $4; $7 ] }
  | simple_expr DOT LBRACKET seq_expr RBRACKET LESSMINUS expr { array_op "String" "set" [ $1; $4; $7 ] }
  | ASSERT simple_expr %prec prec_appl { mkexp (Eassert $2) }
;
simple_expr:
  | constant { mkexp (Econst $1) }
  | LPAREN seq_expr RPAREN { $2 }
  | BEGIN seq_expr END { $2 }
  | BEGIN END { unit () }
  | constr_longident { mkexp (Econstruct ($1, None)) }
  | LBRACKET expr_semi_list opt_semi RBRACKET { mklist (List.rev $2) }
  | LBRACE lbl_expr_list opt_semi RBRACE { mkexp (Erecord (List.rev $2)) }
  | LBRACE simple_expr WITH lbl_expr_list opt_semi RBRACE { mkexp (Ewith ($2, List.rev $4)) }
  | LBRACKETBAR expr_semi_list opt_semi BARRBRACKET { mkexp (Earray (List.rev $2)) }
  | LBRACKETBAR BARRBRACKET { mkexp (Earray []) }
  | simple_expr DOT label_longident { mkexp (Efield ($1, $3)) }
  | val_longident { mkexp (Eident $1) }
  | PREFIXOP simple_expr { mkexp (Eapply (ident $1, [ $2 ])) }
  | LPAREN seq_expr COLON core_type RPAREN { mkexp (Econstraint ($2, $4)) }
  | simple_expr DOT LPAREN seq_expr RPAREN { array_op "Array" "get" [ $1; $4 ] }
  | simple_expr DOT LBRACKET seq_expr RBRACKET { array_op "String" "get" [ $1; $4 ] }
;
simple_expr_list:
  | simple_expr { [ $1 ] }
  | simple_expr_list simple_expr { $2 :: $1 }
;
expr_comma_list:
  | expr_comma_list COMMA expr { $3 :: $1 }
  | expr COMMA expr { [ $3; $1 ] }
;
expr_semi_list:
  | expr %prec prec_list { [ $1 ] }
  | expr_semi_list SEMI expr %prec prec_list { $3 :: $1 }
;
lbl_expr_list:
  | label_longident EQUAL expr %prec prec_list { [ $1, $3 ] }
  | lbl_expr_list SEMI label_longident EQUAL expr %prec prec_list { ($3, $5) :: $1 }
;
fun_def:
  | MINUSGREATER seq_expr { $2 }
  | simple_pattern fun_def { mkfun $1 $2 }
;
let_bindings:
  | let_binding { [ $1 ] }
  | let_bindings AND let_binding { $3 :: $1 }
;
let_binding:
  | val_ident fun_binding { (mkpat (Pvar $1), $2) }
  | pattern EQUAL seq_expr %prec prec_let { ($1, $3) }
;
fun_binding:
  | EQUAL seq_expr %prec prec_let { $2 }
  | simple_pattern fun_binding { mkfun $1 $2 }
  | COLON core_type EQUAL seq_expr %prec prec_let { mkexp (Econstraint ($4, $2)) }
;
match_cases:
  | pattern match_action { [ let g, e = $2 in ($1, g, e) ] }
  | match_cases BAR pattern match_action { (let g, e = $4 in ($3, g, e)) :: $1 }
;
match_action:
  | MINUSGREATER seq_expr { (None, $2) }
  | WHEN seq_expr MINUSGREATER seq_expr { (Some $2, $4) }
;

/* patterns */

pattern:
  | simple_pattern { $1 }
  | constr_longident pattern %prec prec_constr_appl { mkpat (Pconstruct ($1, Some $2)) }
  | pattern COLONCOLON pattern { mkpat (Pconstruct ([ "::" ], Some (mkpat (Ptuple [ $1; $3 ])))) }
  | pattern_comma_list { mkpat (Ptuple (List.rev $1)) }
  | pattern AS val_ident { mkpat (Palias ($1, $3)) }
  | pattern BAR pattern { mkpat (Por ($1, $3)) }
;
simple_pattern:
  | signed_constant { mkpat (Pconst $1) }
  | CHAR DOTDOT CHAR { mkpat (Prange ($1, $3)) }
  | constr_longident { mkpat (Pconstruct ($1, None)) }
  | LBRACE lbl_pattern_list opt_semi RBRACE { mkpat (Precord (List.rev $2)) }
  | val_ident { mkpat (Pvar $1) }
  | UNDERSCORE { mkpat Pany }
  | LPAREN pattern RPAREN { $2 }
  | LPAREN pattern COLON core_type RPAREN { mkpat (Pconstraint ($2, $4)) }
  | LBRACKET pattern_semi_list opt_semi RBRACKET { mkpatlist (List.rev $2) }
;
pattern_comma_list:
  | pattern_comma_list COMMA pattern { $3 :: $1 }
  | pattern COMMA pattern { [ $3; $1 ] }
;
pattern_semi_list:
  | pattern { [ $1 ] }
  | pattern_semi_list SEMI pattern { $3 :: $1 }
;
lbl_pattern_list:
  | label_longident EQUAL pattern { [ $1, $3 ] }
  | lbl_pattern_list SEMI label_longident EQUAL pattern { ($3, $5) :: $1 }
;

/* types */

type_declarations:
  | type_declaration { [ $1 ] }
  | type_declarations AND type_declaration { $3 :: $1 }
;
type_declaration:
  | type_parameters LIDENT type_kind
      { let kind, manifest = $3 in { tname = $2; tparams = $1; tkind = kind; tmanifest = manifest; tloc = loc () } }
;
type_kind:
  | /* empty */ { (Abstract, None) }
  | EQUAL constructor_declarations { (Variant (List.rev $2), None) }
  | EQUAL BAR constructor_declarations { (Variant (List.rev $3), None) }
  | EQUAL LBRACE label_declarations opt_semi RBRACE { (Record (List.rev $3), None) }
  | EQUAL core_type %prec prec_type_def { (Abstract, Some $2) }
  | EQUAL core_type EQUAL opt_bar constructor_declarations %prec prec_type_def { (Variant (List.rev $5), Some $2) }
  | EQUAL core_type EQUAL LBRACE label_declarations opt_semi RBRACE %prec prec_type_def { (Record (List.rev $5), Some $2) }
;
type_parameters:
  | /* empty */ { [] }
  | type_parameter { [ $1 ] }
  | LPAREN type_parameter_list RPAREN { List.rev $2 }
;
type_parameter:
  | QUOTE ident { $2 }
;
type_parameter_list:
  | type_parameter { [ $1 ] }
  | type_parameter_list COMMA type_parameter { $3 :: $1 }
;
constructor_declarations:
  | constructor_declaration { [ $1 ] }
  | constructor_declarations BAR constructor_declaration { $3 :: $1 }
;
constructor_declaration:
  | constr_ident constructor_arguments { ($1, $2) }
;
constructor_arguments:
  | /* empty */ { [] }
  | OF core_type_list { List.rev $2 }
;
label_declarations:
  | label_declaration { [ $1 ] }
  | label_declarations SEMI label_declaration { $3 :: $1 }
;
label_declaration:
  | mutable_flag LIDENT COLON core_type { ($2, $1, $4) }
;
core_type:
  | simple_core_type { $1 }
  | core_type MINUSGREATER core_type %prec prec_type_arrow { Tarrow ($1, $3) }
  | core_type_tuple { Ttuple (List.rev $1) }
;
simple_core_type:
  | QUOTE ident { Tvar $2 }
  | type_longident { Tconstr ($1, []) }
  | simple_core_type type_longident %prec prec_constr_appl { Tconstr ($2, [ $1 ]) }
  | LPAREN core_type_comma_list RPAREN type_longident %prec prec_constr_appl { Tconstr ($4, List.rev $2) }
  | LPAREN core_type RPAREN { $2 }
;
core_type_tuple:
  | simple_core_type STAR simple_core_type { [ $3; $1 ] }
  | core_type_tuple STAR simple_core_type { $3 :: $1 }
;
core_type_list:
  | simple_core_type { [ $1 ] }
  | core_type_list STAR simple_core_type { $3 :: $1 }
;
core_type_comma_list:
  | core_type COMMA core_type { [ $3; $1 ] }
  | core_type_comma_list COMMA core_type { $3 :: $1 }
;

/* names */

ident:
  | UIDENT { $1 }
  | LIDENT { $1 }
;
mod_longident:
  | UIDENT { [ $1 ] }
  | mod_longident DOT UIDENT { $1 @ [ $3 ] }
;
val_ident:
  | LIDENT { $1 }
  | LPAREN operator RPAREN { $2 }
;
operator:
  | PREFIXOP { $1 } | INFIXOP0 { $1 } | INFIXOP1 { $1 } | INFIXOP2 { $1 } | INFIXOP3 { $1 } | INFIXOP4 { $1 }
  | SUBTRACTIVE { $1 } | STAR { "*" } | EQUAL { "=" } | LESS { "<" } | GREATER { ">" } | OR { "or" }
  | BARBAR { "||" } | AMPERSAND { "&" } | AMPERAMPER { "&&" } | COLONEQUAL { ":=" }
;
type_longident:
  | LIDENT { [ $1 ] }
  | mod_longident DOT LIDENT { $1 @ [ $3 ] }
;
constr_ident:
  | UIDENT { $1 }
  | LBRACKET RBRACKET { "[]" }
  | LPAREN RPAREN { "()" }
  | COLONCOLON { "::" }
  | FALSE { "false" }
  | TRUE { "true" }
;
constr_longident:
  | mod_longident { $1 }
  | LBRACKET RBRACKET { [ "[]" ] }
  | LPAREN RPAREN { [ "()" ] }
  | FALSE { [ "false" ] }
  | TRUE { [ "true" ] }
;
label_longident:
  | LIDENT { [ $1 ] }
  | mod_longident DOT LIDENT { $1 @ [ $3 ] }
;
val_longident:
  | val_ident { [ $1 ] }
  | mod_longident DOT val_ident { $1 @ [ $3 ] }
;
constant:
  | INT { Int $1 }
  | CHAR { Char $1 }
  | STRING { String $1 }
  | FLOAT { Float $1 }
;
signed_constant:
  | constant { $1 }
  | SUBTRACTIVE INT { Int (- $2) }
  | SUBTRACTIVE FLOAT { Float ("-" ^ $2) }
;
primitive_declaration:
  | STRING { [ $1 ] }
  | STRING primitive_declaration { $1 :: $2 }
;
rec_flag:
  | /* empty */ { Nonrec }
  | REC { Rec }
;
mutable_flag:
  | /* empty */ { false }
  | MUTABLE { true }
;
direction_flag:
  | TO { Upto }
  | DOWNTO { Downto }
;
opt_bar:
  | /* empty */ { () }
  | BAR { () }
;
opt_semi:
  | /* empty */ { () }
  | SEMI { () }
;
%%
