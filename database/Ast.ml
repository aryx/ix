(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Ast.mli *)

type data_type = Int | Double | Char | Text
type literal = L_int of int | L_double of float | L_char of char | L_text of string
type column_ref = { table : string option; column : string }
type func = Count | Sum | Avg | Min | Max
type binop = Plus | Minus | Multiply | Divide | Concat
type expr = { e : expr_kind; alias : string option }
and expr_kind = Literal of literal | Null | Column of column_ref | Func of func * expr | Binop of binop * expr * expr | Neg of expr
type cmp = Eq | Lt | Gt | Leq | Geq
type cond = Cmp of cmp * expr * expr | And of cond * cond | Or of cond * cond | Not of cond | In of expr * literal list
type fkey = { own : string option; table : string; column : string option }
type constr = Not_null | Unique | Primary_key | Foreign_key of fkey | Default of literal | Auto_increment | Check of cond | Size of int
type column = { name : string; typ : data_type; constraints : constr list }
type table = { name : string; columns : column list }
type index = { name : string; table : string; column : string; unique : bool }
type table_ref = { name : string; alias : string option }
type order = Asc | Desc
type join_cond = On of cond | Using of string list
type outer = Left | Right | Full
type set_op = Union | Except | Intersect

type sra =
  | Table of table_ref
  | Project of project
  | Select of cond * sra
  | Natural_join of sra * sra
  | Join of sra * sra * join_cond option
  | Outer_join of outer * sra * sra * join_cond option
  | Set_op of set_op * sra * sra

and project = { exprs : expr list; sra : sra; distinct : bool; order_by : (expr * order) option; group_by : expr option }

type stmt =
  | Create_table of table
  | Create_index of index
  | Select_stmt of sra
  | Insert of { table : string; columns : string list option; values : literal list }
  | Delete of { table : string; where : cond }

type t = { stmt : stmt; explain : bool; text : string }

let line = ref 1

let chidb_append l x = match l with [] -> [ x ] | first :: _ -> [ first; x ]

(* the printers write into a buffer, as chidb's print to stdout *)
let pr = Buffer.add_string
let list b f xs = pr b "["; List.iteri (fun i x -> if i > 0 then pr b ", "; f x) xs; pr b "]"

let type_name = function Int -> "int" | Double -> "double" | Char -> "char" | Text -> "text"

let literal b = function
  | L_int n -> pr b (Printf.sprintf "int %d" n)
  | L_double f -> pr b (Printf.sprintf "double %f" f)
  | L_char c -> pr b (Printf.sprintf "char '%c'" c)
  | L_text s -> pr b (Printf.sprintf "text \"%s\"" s)

let rec expr b (x : expr) =
  let term = match x.e with Literal _ | Null | Column _ | Func _ -> true | Binop _ | Neg _ -> false in
  if not term then pr b "(";
  (match x.e with
   | Literal l -> literal b l
   | Null -> pr b "NULL"
   | Column { table; column } -> Option.iter (fun t -> pr b (t ^ ".")) table; pr b column
   | Func (f, a) ->
       pr b (match f with Avg -> "AVG(" | Count -> "COUNT(" | Max -> "MAX(" | Min -> "MIN(" | Sum -> "SUM(");
       expr b a;
       pr b ")"
   | Binop (op, l, r) ->
       expr b l;
       pr b (match op with Concat -> " || " | Plus -> " + " | Minus -> " - " | Multiply -> " * " | Divide -> " / ");
       expr b r
   | Neg a -> pr b "-"; expr b a);
  if not term then pr b ")";
  Option.iter (fun a -> pr b (" as " ^ a)) x.alias

let rec cond b = function
  | Cmp (op, l, r) ->
      expr b l;
      pr b (match op with Eq -> " = " | Lt -> " < " | Gt -> " > " | Leq -> " <= " | Geq -> " >= ");
      expr b r
  | And (l, r) -> cond b l; pr b " and "; cond b r
  | Or (l, r) -> cond b l; pr b " or "; cond b r
  | Not (Cmp (Eq, l, r)) -> expr b l; pr b " != "; expr b r
  | Not c -> pr b "not ("; cond b c; pr b ")"
  | In (e, ls) -> expr b e; pr b " in "; list b (literal b) ls

let join_cond b = function
  | On c -> pr b "On: "; cond b c
  | Using cols -> pr b "Using: "; list b (pr b) cols

(* chidb's indent_print: the depth's tabs, then the text; upInd and
 * downInd a newline each, around a deeper level *)
let rec sra b ind (s : sra) =
  let ip text = pr b (String.make ind '\t'); pr b text in
  let nested f = pr b "\n"; f (ind + 1); pr b "\n" in
  match s with
  | Table { name; alias } -> ip ("Table(" ^ name); Option.iter (fun a -> pr b (" as " ^ a)) alias; pr b ")"
  | Select (c, r) ->
      ip "Select(";
      cond b c;
      pr b ", ";
      nested (fun ind -> sra b ind r);
      ip ")"
  | Project p ->
      ip "Project(";
      list b (expr b) p.exprs;
      pr b ", ";
      nested (fun ind ->
        sra b ind p.sra;
        if p.distinct || p.group_by <> None || p.order_by <> None then begin
          pr b ",\n";
          pr b (String.make ind '\t');
          pr b "Options: ";
          if p.distinct then pr b "Distinct ";
          Option.iter (fun g -> pr b "Group by "; expr b g; pr b " ") p.group_by;
          Option.iter (fun (o, dir) -> pr b "Order by "; expr b o; pr b (match dir with Asc -> " a" | Desc -> " de"); pr b "scending") p.order_by
        end);
      ip ")"
  | Set_op (op, l, r) ->
      ip (match op with Union -> "Union(" | Except -> "Except(" | Intersect -> "Intersect(");
      nested (fun ind -> sra b ind l; pr b (String.make ind '\t'); pr b ", "; sra b ind r);
      ip ")"
  | Join (l, r, jc) ->
      ip "Join(";
      nested (fun ind ->
        sra b ind l;
        pr b ", \n";
        sra b ind r;
        Option.iter (fun jc -> pr b ",\n"; pr b (String.make ind '\t'); join_cond b jc) jc);
      ip ")"
  | Natural_join (l, r) ->
      ip "NaturalJoin(";
      nested (fun ind -> sra b ind l; pr b ", \n"; sra b ind r);
      ip ")"
  | Outer_join (o, l, r, jc) ->
      ip (match o with Left -> "Left" | Right -> "Right" | Full -> "Full");
      pr b "OuterJoin(";
      nested (fun ind ->
        sra b ind l;
        pr b ",\n";
        sra b ind r;
        Option.iter (fun jc -> pr b ",\n"; pr b (String.make ind '\t'); join_cond b jc) jc);
      ip ")"

let constr b = function
  | Default l -> pr b "Default: "; literal b l
  | Primary_key -> pr b "Primary Key"
  | Unique -> pr b "Unique"
  | Foreign_key { table; column; _ } ->
      pr b (Printf.sprintf "Foreign key (%s, %s)" table (Option.value column ~default:"(null)"))
  | Auto_increment -> pr b "Auto increment"
  | Not_null -> pr b "Not null"
  | Check c -> pr b "Check: "; cond b c
  | Size n -> pr b (Printf.sprintf "Size: %d" n)

let stmt b = function
  | Create_table { name; columns } ->
      pr b (Printf.sprintf "CREATE Table %s (\n" name);
      (* claude: chidb's Table_print stops at the 10th column *)
      List.iteri (fun i (c : column) ->
        if i < 10 then begin
          if i > 0 then pr b ",\n";
          pr b (Printf.sprintf "\t%s %s" c.name (type_name c.typ));
          if c.constraints <> [] then (pr b " "; list b (constr b) c.constraints)
        end) columns;
      pr b "\n)\n"
  | Create_index { table; column; unique; _ } ->
      (* claude: chidb prints the column's name as the index's *)
      pr b (Printf.sprintf "CREATE Index '%s' on %s (%s)" column table column);
      if unique then pr b ", unique";
      pr b "\n"
  | Select_stmt s -> sra b 0 s
  | Insert { table; columns; values } ->
      pr b "Insert ";
      list b (literal b) values;
      pr b (" into " ^ table);
      Option.iter (fun cols -> pr b " using columns "; list b (pr b) cols) columns;
      pr b "\n"
  | Delete { table; where } -> pr b (Printf.sprintf "Delete from %s where " table); cond b where; pr b "\n"

let to_string f x = let b = Buffer.create 256 in f b x; Buffer.contents b
let show (t : t) = to_string stmt t.stmt
let show_sra = to_string (fun b -> sra b 0)
let show_cond = to_string cond
let show_expr = to_string expr
