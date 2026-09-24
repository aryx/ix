/* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 */
/* The grammar: chidb's sql.y, rule for rule, so that ocamlyacc's
 * LALR(1) tables have bison's conflicts, resolved the same way (a
 * shift over a reduce, the earlier rule of two reduces). A statement's
 * value is Some statement, or None for an empty one, with its EXPLAIN
 * flag. The C's list builders are kept where their result shows
 * (Ast.chidb_append); key declarations are applied to their columns
 * as Table_make does, with its messages. */
%{
open Ast

let warn fmt = Printf.eprintf fmt

(* PRIMARY KEY (c, ...) and FOREIGN KEY (c) REFERENCES ..., applied *)
type key_dec = Primary of string list | Foreign of fkey

let apply_key_decs (columns : column list) decs =
  let add name c columns =
    if List.exists (fun (col : column) -> col.name = name) columns then
      Some (List.map (fun (col : column) -> if col.name = name then { col with constraints = chidb_append col.constraints c } else col) columns)
    else None in
  List.fold_left (fun columns dec ->
    match dec with
    | Primary names ->
        List.fold_left (fun columns n ->
          match add n Primary_key columns with
          | Some columns -> columns
          | None -> warn "Error: column '%s' not found\n" n; columns) columns names
    | Foreign fk ->
        let own = Option.value fk.own ~default:"" in
        match add own (Foreign_key fk) columns with
        | Some columns -> columns
        | None -> warn "Error: column %s not in table\n" own; columns) columns decs

let literal s = if String.length s = 1 then L_char s.[0] else L_text s
let expr e = { e; alias = None }
%}

%token CREATE TABLE INSERT INTO SELECT FROM WHERE FULL
%token PRIMARY FOREIGN KEY DEFAULT CHECK NOT NULL
%token AND OR NEQ GEQ LEQ REFERENCES ORDER BY DELETE
%token AS INT BYTE DOUBLE CHAR VARCHAR TEXT USING CONSTRAINT
%token JOIN INNER OUTER LEFT RIGHT NATURAL CROSS UNION BOWTIE
%token VALUES AUTO_INCREMENT ASC DESC UNIQUE IN ON
%token COUNT SUM AVG MIN MAX INTERSECT EXCEPT DISTINCT
%token CONCAT TRUE FALSE CASE WHEN DECLARE BIT GROUP
%token INDEX EXPLAIN
%token SEMI COMMA LPAREN RPAREN DOT STAR PLUS MINUS SLASH EQ LT GT OTHER EOF
%token <string> IDENTIFIER
%token <string> STRING_LITERAL
%token <float> DOUBLE_LITERAL
%token <int> INT_LITERAL

%start main
%type <(Ast.stmt option * bool) list> main

%%

/* bison's implicit end of input, made explicit */
main: sql_queries EOF { $1 };

sql_queries:
  | sql_query { [ $1 ] }
  | sql_queries sql_query { $1 @ [ $2 ] }
  ;

sql_query:
  | sql_line SEMI { ($1, false) }
  | EXPLAIN sql_line SEMI { ($2, true) }
  ;

sql_line:
  | create { Some $1 }
  | select { Some (Select_stmt $1) }
  | insert_into { Some $1 }
  | delete_from { Some $1 }
  | /* empty */ { None }
  ;

create:
  | create_table { Create_table $1 }
  | create_index { Create_index $1 }
  ;

create_index:
  | CREATE opt_unique INDEX index_name ON table_name LPAREN column_name RPAREN
      { { name = $4; table = $6; column = $8; unique = $2 } }
  ;

opt_unique:
  | UNIQUE { true }
  | /* empty */ { false }
  ;

index_name: IDENTIFIER { $1 };

create_table:
  | CREATE TABLE table_name LPAREN column_dec_list opt_key_dec_list RPAREN
      { { name = $3; columns = apply_key_decs $5 $6 } }
  ;

column_dec_list:
  | column_dec { [ $1 ] }
  | column_dec_list COMMA column_dec { $1 @ [ $3 ] }
  ;

column_dec:
  | column_name column_type opt_constraints
      { let typ, size = $2 in
        (* chidb's Column: a size is appended to the constraints, lost
         * if there are none *)
        let constraints = match size, $3 with Some n, (_ :: _ as cs) -> chidb_append cs (Size n) | _, cs -> cs in
        { name = $1; typ; constraints } }
  ;

column_type:
  | INT { (Int, None) }
  | DOUBLE { (Double, None) }
  | CHAR { (Char, None) }
  | VARCHAR { (Text, None) }
  | TEXT { (Text, None) }
  | column_type LPAREN INT_LITERAL RPAREN
      { if $3 <= 0 then failwith (Printf.sprintf "sizes must be greater than 0 (line %d)" !Ast.line);
        (fst $1, Some $3) }
  ;

opt_key_dec_list:
  | COMMA key_dec_list { $2 }
  | /* empty */ { [] }
  ;

key_dec_list:
  | key_dec { [ $1 ] }
  | key_dec_list COMMA key_dec { chidb_append $1 $3 }
  ;

key_dec:
  | PRIMARY KEY LPAREN column_names_list RPAREN { Primary $4 }
  | FOREIGN KEY LPAREN column_name RPAREN references_stmt { Foreign { $6 with own = Some $4 } }
  ;

references_stmt:
  | REFERENCES table_name { { own = None; table = $2; column = None } }
  | REFERENCES table_name LPAREN column_name RPAREN { { own = None; table = $2; column = Some $4 } }
  ;

opt_constraints:
  | constraints { $1 }
  | /* empty */ { [] }
  ;

constraints:
  | constraint_ { [ $1 ] }
  | constraint_ constraints { chidb_append $2 $1 }
  ;

constraint_:
  | NOT NULL { Not_null }
  | UNIQUE { Unique }
  | PRIMARY KEY { Primary_key }
  | FOREIGN KEY references_stmt { Foreign_key $3 }
  | DEFAULT literal_value { Default $2 }
  | AUTO_INCREMENT { Auto_increment }
  | CHECK condition { Check $2 }
  ;

select:
  | select_statement { $1 }
  | select select_combo select_statement { Set_op ($2, $1, $3) }
  ;

select_combo:
  | UNION { Union }
  | INTERSECT { Intersect }
  | EXCEPT { Except }
  ;

select_statement:
  | SELECT opt_distinct expression_list FROM table opt_where_condition opt_options
      { let sra = match $6 with Some c -> Select (c, $5) | None -> $5 in
        let order_by, group_by = $7 in
        Project { exprs = $3; sra; distinct = $2; order_by; group_by } }
  | LPAREN select_statement RPAREN { $2 }
  ;

opt_distinct:
  | DISTINCT { true }
  | /* empty */ { false }
  ;

opt_options:
  | order_by { (Some $1, None) }
  | group_by { (None, Some $1) }
  | order_by group_by { (Some $1, Some $2) }
  | group_by order_by { (Some $2, Some $1) }
  | /* empty */ { (None, None) }
  ;

opt_where_condition:
  | where_condition { Some $1 }
  | /* empty */ { None }
  ;

where_condition: WHERE condition { $2 };

group_by: GROUP BY expression { $3 };

order_by:
  | ORDER BY expression { ($3, Asc) }
  | ORDER BY expression ASC { ($3, Asc) }
  | ORDER BY expression DESC { ($3, Desc) }
  ;

condition:
  | bool_term { $1 }
  | bool_term bool_op condition { if $2 then And ($1, $3) else Or ($1, $3) }
  ;

bool_term:
  | expression comp_op expression { match $2 with Some op -> Cmp (op, $1, $3) | None -> Not (Cmp (Eq, $1, $3)) }
  | expression in_statement { In ($1, $2) }
  | LPAREN condition RPAREN { $2 }
  | NOT bool_term { Not $2 }
  ;

in_statement:
  | IN LPAREN values_list RPAREN { $3 }
  | IN LPAREN select RPAREN { warn "****WARNING: IN SELECT statement not yet supported\n"; [] }
  ;

bool_op:
  | AND { true }
  | OR { false }
  ;

comp_op:
  | EQ { Some Eq }
  | GT { Some Gt }
  | LT { Some Lt }
  | GEQ { Some Geq }
  | LEQ { Some Leq }
  | NEQ { None }
  ;

expression_list:
  | expression opt_alias { [ { $1 with alias = $2 } ] }
  | expression_list COMMA expression opt_alias { $1 @ [ { $3 with alias = $4 } ] }
  ;

expression:
  | expression PLUS mulexp { expr (Binop (Plus, $1, $3)) }
  | expression MINUS mulexp { expr (Binop (Minus, $1, $3)) }
  | mulexp { $1 }
  ;

mulexp:
  | mulexp STAR primary { expr (Binop (Multiply, $1, $3)) }
  | mulexp SLASH primary { expr (Binop (Divide, $1, $3)) }
  | mulexp CONCAT primary { expr (Binop (Concat, $1, $3)) }
  | primary { $1 }
  ;

primary:
  | LPAREN expression RPAREN { $2 }
  | MINUS primary { expr (Neg $2) }
  | term { $1 }
  ;

term:
  | literal_value { expr (Literal $1) }
  | NULL { expr Null }
  | column_reference { expr (Column $1) }
  | function_name LPAREN expression RPAREN { expr (Func ($1, $3)) }
  ;

column_reference:
  | column_name_or_star { { table = None; column = $1 } }
  | table_name DOT column_name_or_star { { table = Some $1; column = $3 } }
  ;

opt_alias:
  | AS IDENTIFIER { Some $2 }
  | IDENTIFIER { Some $1 }
  | /* empty */ { None }
  ;

function_name:
  | COUNT { Count }
  | SUM { Sum }
  | AVG { Avg }
  | MIN { Min }
  | MAX { Max }
  ;

column_name_or_star:
  | STAR { "*" }
  | column_name { $1 }
  ;

column_name: IDENTIFIER { $1 };

table_name: IDENTIFIER { $1 };

table:
  | table_ref { Table $1 }
  | table default_join table_ref opt_join_condition { Join ($1, Table $3, $4) }
  | table join table_ref opt_join_condition
      { match $2 with
        | None ->
            if $4 <> None then
              warn "Line %d: WARNING: a NATURAL join cannot have an ON or USING clause. This will be ignored.\n" !Ast.line;
            Natural_join ($1, Table $3)
        | Some o -> Outer_join (o, $1, Table $3, $4) }
  ;

opt_join_condition:
  | join_condition { Some $1 }
  | /* empty */ { None }
  ;

join_condition:
  | ON condition { On $2 }
  | USING LPAREN column_names_list RPAREN { Using $3 }
  ;

table_ref: table_name opt_alias { { name = $1; alias = $2 } };

/* None: a natural join */
join:
  | LEFT opt_outer JOIN { Some Left }
  | RIGHT opt_outer JOIN { Some Right }
  | FULL opt_outer JOIN { Some Full }
  | NATURAL JOIN { None }
  | BOWTIE { None }
  ;

default_join:
  | COMMA { () }
  | JOIN { () }
  | CROSS JOIN { () }
  | INNER JOIN { () }
  ;

opt_outer:
  | OUTER { () }
  | /* empty */ { () }
  ;

insert_into:
  | INSERT INTO table_name opt_column_names VALUES LPAREN values_list RPAREN
      { (match $4 with
         | Some cols when List.length cols > List.length $7 -> warn "Error: more column names specified than values\n"; raise Parsing.Parse_error
         | Some cols when List.length cols < List.length $7 -> warn "Error: more values specified than column names\n"; raise Parsing.Parse_error
         | _ -> ());
        Insert { table = $3; columns = $4; values = $7 } }
  ;

opt_column_names:
  | LPAREN column_names_list RPAREN { Some $2 }
  | /* empty */ { None }
  ;

column_names_list:
  | column_name { [ $1 ] }
  | column_names_list COMMA column_name { $1 @ [ $3 ] }
  ;

values_list:
  | literal_value { [ $1 ] }
  | values_list COMMA literal_value { $1 @ [ $3 ] }
  ;

literal_value:
  | INT_LITERAL { L_int $1 }
  | DOUBLE_LITERAL { L_double $1 }
  | STRING_LITERAL { literal $1 }
  ;

delete_from:
  | DELETE FROM table_name where_condition { Delete { table = $3; where = $4 } }
  ;
