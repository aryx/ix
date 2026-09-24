(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Codegen.mli *)
open Dbm

type program = { code : int Dbm.instr array; columns : string list; schema_change : bool }

exception Invalid

(*****************************************************************************)
(* Emitting, with labels *)
(*****************************************************************************)

type label = L of int [@@unboxed]

(* old: chidb emits into an array and patches forward jumps later
 * (stmt->ops[addr].p2 = pc), keeping the addresses to patch in arrays *)
type item = Ins of label instr | Place of label

type code = { mutable items : item list; mutable labels : int }

let emit c i = c.items <- Ins i :: c.items
let label c = c.labels <- c.labels + 1; L c.labels
let place c l = c.items <- Place l :: c.items

(* numbered, the labels resolved *)
let resolve c : int instr array =
  let items = List.rev c.items in
  let addr = Hashtbl.create 16 in
  ignore (List.fold_left (fun pc -> function Ins _ -> pc + 1 | Place (L l) -> Hashtbl.replace addr l pc; pc) 0 items);
  Array.of_list (List.filter_map (function
    | Ins i -> Some (map_jump (fun (L l) -> Hashtbl.find addr l) i)
    | Place _ -> None) items)

(*****************************************************************************)
(* Columns and literals *)
(*****************************************************************************)

let same a b = String.lowercase_ascii a = String.lowercase_ascii b

let index_of (columns : Ast.column list) name =
  let rec go i = function
    | [] -> None
    | (c : Ast.column) :: rest -> if same c.name name then Some (i, c.typ) else go (i + 1) rest in
  go 0 columns

let is_pk (columns : Ast.column list) i = List.mem Ast.Primary_key (List.nth columns i).constraints

(* the first column with a PRIMARY KEY, or the first *)
let pk_index (columns : Ast.column list) =
  let rec go i = function [] -> 0 | (c : Ast.column) :: rest -> if List.mem Ast.Primary_key c.constraints then i else go (i + 1) rest in
  go 0 columns

let name_at (columns : Ast.column list) i = (List.nth columns i).name

let emit_literal c (lit : Ast.literal) r =
  match lit with
  | L_int n -> emit c (Integer (n, r))
  | L_char ch -> emit c (String (1, r, String.make 1 ch))
  | L_text s -> emit c (String (String.length s, r, s))
  | L_double _ -> raise Invalid

let matches (lit : Ast.literal) (typ : Ast.data_type) =
  match typ, lit with
  | Int, L_int _ -> true
  | Text, (L_text _ | L_char _) -> true
  | (Int | Double | Char | Text), _ -> false

(*****************************************************************************)
(* WHERE clauses: conjuncts column OP literal *)
(*****************************************************************************)

(* a column of one table (side 0) or of a join's two (0 left, 1 right) *)
type rcol = { side : int; idx : int }

(* a conjunct, its comparison negated: the jump taken when it is false *)
type resolved = { col : rcol; op : Dbm.cmp; lit : Ast.literal }

let rec conjuncts : Ast.cond -> Ast.cond list = function And (a, b) -> conjuncts a @ conjuncts b | c -> [ c ]

let resolve_cmp (resolve : Ast.column_ref -> (rcol * Ast.data_type) option) : Ast.cond -> resolved = function
  | Cmp (op, e1, e2) -> (
      let col, v, flipped = match e1.e, e2.e with
        | Column r, _ -> r, e2, false
        | _, Column r -> r, e1, true
        | _ -> raise Invalid in
      let lit = match v.e with Literal l -> l | _ -> raise Invalid in
      match resolve col with
      | Some (col, typ) when matches lit typ ->
          let op = match op, flipped with
            | Eq, _ -> Ast.Eq | Lt, false | Gt, true -> Lt | Gt, false | Lt, true -> Gt
            | Leq, false | Geq, true -> Leq | Geq, false | Leq, true -> Geq in
          { col; lit; op = (match op with Eq -> Ne | Gt -> Le | Geq -> Lt | Lt -> Ge | Leq -> Gt) }
      | _ -> raise Invalid)
  | And _ | Or _ | Not _ | In _ -> raise Invalid

let resolve_all resolve = function None -> [] | Some c -> List.map (resolve_cmp resolve) (conjuncts c)

(* the seek for a negated comparison, and whether its walk goes forward *)
let seek_of : Dbm.cmp -> Cursor.seek = function
  | Ne -> Eq | Le -> Gt | Lt -> Ge | Ge -> Lt | Gt -> Le | Eq -> Eq
let forward : Cursor.seek -> bool = function Gt | Ge -> true | Eq | Lt | Le -> false

(* two conjuncts, a lower and an upper bound on one column: which is
 * which *)
let range_pair = function
  | [ a; b ] when a.col = b.col -> (
      let lower (r : resolved) = match seek_of r.op with Gt | Ge -> true | Eq | Lt | Le -> false in
      let upper (r : resolved) = match seek_of r.op with Lt | Le -> true | Eq | Gt | Ge -> false in
      if lower a && upper b then Some (a, b) else if lower b && upper a then Some (b, a) else None)
  | _ -> None

(* the seeking conjunct, and the range's other bound *)
let seekable = function [ r ] -> Some (r, None) | rs -> Option.map (fun (lo, hi) -> lo, Some hi) (range_pair rs)

(* a column's value into a register: Key for the primary key *)
let emit_col c cursor columns i r = if is_pk columns i then emit c (Key (C cursor, R r)) else emit c (Column (C cursor, i, R r))

let emit_rcol c cols1 cols2 (rc : rcol) r = emit_col c rc.side (if rc.side = 0 then cols1 else cols2) rc.idx r

let emit_checks c cols1 cols2 cmps lit_base tmp target =
  List.iteri (fun i (r : resolved) -> emit_rcol c cols1 cols2 r.col tmp; emit c (Cmp (r.op, R (lit_base + i), target, R tmp))) cmps

(*****************************************************************************)
(* CREATE TABLE, CREATE INDEX *)
(*****************************************************************************)

(* the schema row: r1..r5, the new root in r4, the record in r6, the
 * key in r7 *)
let schema_row c schema kind name table sql =
  emit c (Integer (1, R 0));
  emit c (Open_write (C 0, R 0, 5));
  emit c (Create (kind, R 4));
  let str s r = emit c (String (String.length s, R r, s)) in
  str (match kind with Btree.Table -> "table" | Index -> "index") 1;
  str name 2;
  str table 3;
  str sql 5;
  emit c (Make_record (R 1, 5, R 6));
  emit c (Integer (Schema.next_key schema, R 7));
  emit c (Insert (C 0, R 6, R 7));
  emit c (Close (C 0))

let create_table c schema (t : Ast.table) sql =
  if Schema.find_table schema t.name <> None then raise Invalid;
  schema_row c schema Table t.name t.name sql;
  emit c Halt

let create_index c schema (x : Ast.index) sql =
  let tbl = match Schema.find_table schema x.table with Some t -> t | None -> raise Invalid in
  let columns = Schema.columns tbl in
  let col = match index_of columns x.column with Some (i, Int) -> i | _ -> raise Invalid in
  schema_row c schema Index x.name x.table sql;
  emit c (Open_write (C 2, R 4, 0));
  emit c (Integer (tbl.root, R 8));
  emit c (Open_read (C 1, R 8, List.length columns));
  let loop = label c and after = label c in
  emit c (Rewind (C 1, after));
  place c loop;
  emit_col c 1 columns col 9;
  emit c (Key (C 1, R 10));
  emit c (Idx_insert (C 2, R 9, R 10));
  emit c (Next (C 1, loop));
  place c after;
  emit c (Close (C 1));
  emit c (Close (C 2));
  emit c Halt

(*****************************************************************************)
(* INSERT *)
(*****************************************************************************)

(* r0 the root, r1 the key, r2.. the columns (NULL for the primary key),
 * then the record, then a register and a cursor per index *)
let insert c schema table (values : Ast.literal list) =
  let tbl = match Schema.find_table schema table with Some t -> t | None -> raise Invalid in
  let columns = Schema.columns tbl in
  let ncols = List.length columns and pk = pk_index columns in
  if List.length values <> ncols || not (List.for_all2 (fun v (col : Ast.column) -> matches v col.typ) values columns) then raise Invalid;
  emit c (Integer (tbl.root, R 0));
  emit c (Open_write (C 0, R 0, ncols));
  (* claude: chidb takes the primary key's literal as an int even when it
   * is not one (a TEXT primary key), reading its string pointer's bits;
   * refused here *)
  emit c (Integer ((match List.nth values pk with L_int n -> n | L_char _ | L_text _ | L_double _ -> raise Invalid), R 1));
  List.iteri (fun i v -> if i = pk then emit c (Null (R (2 + i))) else emit_literal c v (R (2 + i))) values;
  let record = 2 + ncols in
  emit c (Make_record (R 2, ncols, R record));
  emit c (Insert (C 0, R record, R 1));
  ignore (List.fold_left (fun (reg, cursor) (item : Schema.item) ->
    if item.kind <> Index || not (same item.table table) then (reg, cursor)
    else match Option.bind (Schema.index_column item) (index_of columns) with
      | None -> (reg, cursor)
      | Some (i, _) ->
          emit c (Integer (item.root, R reg));
          emit c (Open_write (C cursor, R reg, 0));
          emit c (Idx_insert (C cursor, R (if i = pk then 1 else 2 + i), R 1));
          emit c (Close (C cursor));
          (reg + 1, cursor + 1)) (record + 1, 1) schema);
  emit c (Close (C 0));
  emit c Halt

(*****************************************************************************)
(* SELECT from one table *)
(*****************************************************************************)

let output c cursor columns outs r0 =
  List.iteri (fun i idx -> emit_col c cursor columns idx (r0 + i)) outs;
  emit c (Result_row (R r0, List.length outs))

(* index seek: cursor 0 the index, 1 the table; for a range, a walk
 * from the seek, the other bound checked on each row *)
let select_indexed c (tbl : Schema.item) (idx : Schema.item) columns outs (cmp : resolved) bound2 =
  let r_lit2, r_tmp2, r_out0 = match bound2 with Some _ -> 4, 5, 6 | None -> -1, -1, 4 in
  let kind = seek_of cmp.op in
  emit c (Integer (idx.root, R 0));
  emit c (Open_read (C 0, R 0, 0));
  emit c (Integer (tbl.root, R 1));
  emit c (Open_read (C 1, R 1, List.length columns));
  emit_literal c cmp.lit (R 2);
  Option.iter (fun (b : resolved) -> emit_literal c b.lit (R r_lit2)) bound2;
  let tail = label c and loop = label c and after = label c in
  emit c (Seek (kind, C 0, tail, R 2));
  place c loop;
  emit c (Idx_pkey (C 0, R 3));
  emit c (Seek (Eq, C 1, after, R 3));
  Option.iter (fun (b : resolved) ->
    emit_col c 1 columns b.col.idx r_tmp2;
    emit c (Cmp (b.op, R r_lit2, tail, R r_tmp2))) bound2;
  output c 1 columns outs r_out0;
  place c after;
  if kind <> Eq then emit c ((if forward kind then fun (x, y) -> Next (x, y) else fun (x, y) -> Prev (x, y)) (C 0, loop));
  place c tail;
  emit c (Close (C 1));
  emit c (Close (C 0));
  emit c Halt

let select_scan c (tbl : Schema.item) columns outs cmps =
  let ncmp = List.length cmps in
  let tmp = 1 + ncmp in
  let r_out0 = if ncmp = 0 then 1 else tmp + 1 in
  emit c (Integer (tbl.root, R 0));
  emit c (Open_read (C 0, R 0, List.length columns));
  List.iteri (fun i (r : resolved) -> emit_literal c r.lit (R (1 + i))) cmps;
  let loop = label c and next = label c and after = label c in
  emit c (Rewind (C 0, after));
  place c loop;
  emit_checks c columns [] cmps 1 tmp next;
  output c 0 columns outs r_out0;
  place c next;
  emit c (Next (C 0, loop));
  place c after;
  emit c (Close (C 0));
  emit c Halt

let is_star : Ast.expr list -> bool = function [ { e = Column { column = "*"; _ }; _ } ] -> true | _ -> false

(*****************************************************************************)
(* SELECT from a NATURAL JOIN *)
(*****************************************************************************)

(* how one side is read: a scan with its conjuncts as filters; one
 * index seek (an equality: no loop); or a seek and a walk (a range,
 * maybe with the other bound checked on each row) *)
type access =
  | Scan
  | Eq_seek of Schema.item * resolved
  | Range_seek of Schema.item * resolved * resolved option

let plan_side schema table columns cmps =
  match seekable cmps with
  | None -> Scan
  | Some (primary, bound2) -> (
      match Schema.find_index_on schema table (name_at columns primary.col.idx) with
      | None -> Scan
      | Some idx -> if seek_of primary.op = Eq then Eq_seek (idx, primary) else Range_seek (idx, primary, bound2))

(* a column of the join, by its table's name or alias, or unqualified
 * (the left table first: a name in both is a join column, equal on
 * both sides) *)
let join_resolver (cols1, name1, alias1) (cols2, name2, alias2) (r : Ast.column_ref) =
  let named n a t = same t n || match a with Some a -> same t a | None -> false in
  let on side cols = Option.map (fun (idx, typ) -> { side; idx }, typ) (index_of cols r.column) in
  match r.table with
  | Some t when named name1 alias1 t -> on 0 cols1
  | Some t when named name2 alias2 t -> on 1 cols2
  | Some _ -> None
  | None -> (match on 0 cols1 with Some x -> Some x | None -> on 1 cols2)

let select_join c schema (s1 : Ast.sra) (s2 : Ast.sra) (exprs : Ast.expr list) cond =
  let unwrap : Ast.sra -> Ast.cond option * Ast.table_ref = function
    | Select (cond, Table t) -> Some cond, t
    | Table t -> None, t
    | Select _ | Project _ | Natural_join _ | Join _ | Outer_join _ | Set_op _ -> raise Invalid in
  let cond1, t1 = unwrap s1 and cond2, t2 = unwrap s2 in
  let find n = match Schema.find_table schema n with Some t -> t | None -> raise Invalid in
  let tbl1 = find t1.name and tbl2 = find t2.name in
  let cols1 = Schema.columns tbl1 and cols2 = Schema.columns tbl2 in
  let ncols1 = List.length cols1 and ncols2 = List.length cols2 in
  let resolve = join_resolver (cols1, t1.name, t1.alias) (cols2, t2.name, t2.alias) in
  (* the natural join's pairs: every name in both tables *)
  let pairs = List.concat (List.mapi (fun i (col : Ast.column) -> match index_of cols2 col.name with Some (j, _) -> [ i, j ] | None -> []) cols1) in
  let outs =
    if is_star exprs then
      List.init ncols1 (fun idx -> { side = 0; idx })
      @ List.filter_map (fun idx -> if List.exists (fun (_, j) -> j = idx) pairs then None else Some { side = 1; idx }) (List.init ncols2 Fun.id)
    else List.map (fun (e : Ast.expr) -> match e.e with Column r -> (match resolve r with Some (rc, _) -> rc | None -> raise Invalid) | _ -> raise Invalid) exprs in
  let cmps1 = resolve_all resolve cond1 and cmps2 = resolve_all resolve cond2 and top = resolve_all resolve cond in
  let acc1 = plan_side schema t1.name cols1 cmps1 and acc2 = plan_side schema t2.name cols2 cmps2 in
  let scan1 = if acc1 = Scan then cmps1 else [] and scan2 = if acc2 = Scan then cmps2 else [] in
  let bound2 = function Range_seek (_, _, b) -> b | Scan | Eq_seek _ -> None in
  (* the registers, in chidb's order *)
  let next = ref 0 in
  let reg ?(if_ = true) () = if if_ then (let r = !next in incr next; r) else -1 in
  let seeks1 = acc1 <> Scan and seeks2 = acc2 <> Scan in
  let r_idxroot1 = reg ~if_:seeks1 () in
  let r_root1 = reg () in
  let r_idxroot2 = reg ~if_:seeks2 () in
  let r_root2 = reg () in
  let r_lit1 = reg ~if_:seeks1 () in
  let r_pkey1 = reg ~if_:seeks1 () in
  let r_lit1b = reg ~if_:(bound2 acc1 <> None) () in
  let r_lit2 = reg ~if_:seeks2 () in
  let r_pkey2 = reg ~if_:seeks2 () in
  let r_lit2b = reg ~if_:(bound2 acc2 <> None) () in
  let lit_base = !next in
  next := !next + List.length scan1 + List.length scan2 + List.length top;
  let tmp_a = reg () in
  let tmp_b = reg () in
  let r_out0 = !next in
  (* every cursor open before any seek or rewind, so that one tail
   * closes them all *)
  let open_side acc cidx r_idxroot (tbl : Schema.item) ctbl r_root ncols =
    (match acc with Eq_seek (idx, _) | Range_seek (idx, _, _) -> emit c (Integer (idx.root, R r_idxroot)); emit c (Open_read (C cidx, R r_idxroot, 0)) | Scan -> ());
    emit c (Integer (tbl.root, R r_root));
    emit c (Open_read (C ctbl, R r_root, ncols)) in
  open_side acc1 2 r_idxroot1 tbl1 0 r_root1 ncols1;
  open_side acc2 3 r_idxroot2 tbl2 1 r_root2 ncols2;
  let lits acc r_lit r_litb = match acc with
    | Eq_seek (_, p) -> emit_literal c p.lit (R r_lit)
    | Range_seek (_, p, b) -> emit_literal c p.lit (R r_lit); Option.iter (fun (b : resolved) -> emit_literal c b.lit (R r_litb)) b
    | Scan -> () in
  lits acc1 r_lit1 r_lit1b;
  lits acc2 r_lit2 r_lit2b;
  let tail = label c in
  (* an equality seek positions its side once, before any loop *)
  let eq_seek acc cidx ctbl r_lit r_pkey = match acc with
    | Eq_seek _ ->
        emit c (Seek (Eq, C cidx, tail, R r_lit));
        emit c (Idx_pkey (C cidx, R r_pkey));
        emit c (Seek (Eq, C ctbl, tail, R r_pkey))
    | Scan | Range_seek _ -> () in
  eq_seek acc1 2 0 r_lit1 r_pkey1;
  eq_seek acc2 3 1 r_lit2 r_pkey2;
  List.iteri (fun i (r : resolved) -> emit_literal c r.lit (R (lit_base + i))) (scan1 @ scan2 @ top);
  (* the outer loop, over the left side *)
  let loop1 = label c and adv1 = label c in
  let outer = match acc1 with Eq_seek _ -> false | Scan | Range_seek _ -> true in
  if outer then begin
    (match acc1 with
     | Range_seek (_, p, _) -> emit c (Seek (seek_of p.op, C 2, tail, R r_lit1))
     | Scan | Eq_seek _ -> emit c (Rewind (C 0, tail)));
    place c loop1;
    match acc1 with
    | Range_seek (_, _, b) ->
        emit c (Idx_pkey (C 2, R r_pkey1));
        emit c (Seek (Eq, C 0, tail, R r_pkey1));
        Option.iter (fun (b : resolved) ->
          emit_col c 0 cols1 b.col.idx tmp_a;
          emit c (Cmp (b.op, R r_lit1b, tail, R tmp_a))) b
    | Scan | Eq_seek _ -> emit_checks c cols1 cols2 scan1 lit_base tmp_a adv1
  end;
  (* the inner loop, over the right side *)
  let loop2 = label c and retry = label c and done_inner = label c in
  let inner = match acc2 with Eq_seek _ -> false | Scan | Range_seek _ -> true in
  if inner then begin
    (match acc2 with
     | Range_seek (_, p, _) -> emit c (Seek (seek_of p.op, C 3, done_inner, R r_lit2))
     | Scan | Eq_seek _ -> emit c (Rewind (C 1, done_inner)));
    place c loop2;
    match acc2 with
    | Range_seek (_, _, b) ->
        emit c (Idx_pkey (C 3, R r_pkey2));
        emit c (Seek (Eq, C 1, tail, R r_pkey2));
        Option.iter (fun (b : resolved) ->
          emit_col c 1 cols2 b.col.idx tmp_a;
          emit c (Cmp (b.op, R r_lit2b, done_inner, R tmp_a))) b
    | Scan | Eq_seek _ -> ()
  end;
  List.iter (fun (i, j) ->
    emit_rcol c cols1 cols2 { side = 0; idx = i } tmp_a;
    emit_rcol c cols1 cols2 { side = 1; idx = j } tmp_b;
    emit c (Cmp (Ne, R tmp_a, retry, R tmp_b))) pairs;
  emit_checks c cols1 cols2 scan2 (lit_base + List.length scan1) tmp_a retry;
  emit_checks c cols1 cols2 top (lit_base + List.length scan1 + List.length scan2) tmp_a retry;
  List.iteri (fun k rc -> emit_rcol c cols1 cols2 rc (r_out0 + k)) outs;
  emit c (Result_row (R r_out0, List.length outs));
  let advance acc ~scan_cursor ~idx_cursor loop =
    match acc with
    | Range_seek (_, p, _) -> emit c (if forward (seek_of p.op) then Next (C idx_cursor, loop) else Prev (C idx_cursor, loop))
    | Scan | Eq_seek _ -> emit c (Next (C scan_cursor, loop)) in
  place c retry;
  if inner then advance acc2 ~scan_cursor:1 ~idx_cursor:3 loop2;
  place c done_inner;
  if outer then (place c adv1; advance acc1 ~scan_cursor:0 ~idx_cursor:2 loop1);
  place c tail;
  emit c (Close (C 1));
  if seeks2 then emit c (Close (C 3));
  emit c (Close (C 0));
  if seeks1 then emit c (Close (C 2));
  emit c Halt;
  List.map (fun (rc : rcol) -> name_at (if rc.side = 0 then cols1 else cols2) rc.idx) outs

(*****************************************************************************)
(* SELECT, and the statements *)
(*****************************************************************************)

let select c schema (sra : Ast.sra) =
  let p = match sra with Project p -> p | _ -> raise Invalid in
  let cond, from = match p.sra with Select (cond, s) -> Some cond, s | s -> None, s in
  match from with
  | Natural_join (s1, s2) -> select_join c schema s1 s2 p.exprs cond
  | Table t -> (
      let tbl = match Schema.find_table schema t.name with Some x -> x | None -> raise Invalid in
      let columns = Schema.columns tbl in
      let outs =
        if is_star p.exprs then List.init (List.length columns) Fun.id
        else List.map (fun (e : Ast.expr) -> match e.e with
          | Column r -> (match index_of columns r.column with Some (i, _) -> i | None -> raise Invalid)
          | _ -> raise Invalid) p.exprs in
      let cmps = resolve_all (fun r -> Option.map (fun (idx, typ) -> { side = 0; idx }, typ) (index_of columns r.column)) cond in
      let indexed = Option.bind (seekable cmps) (fun (primary, bound2) ->
        Option.map (fun idx -> idx, primary, bound2) (Schema.find_index_on schema t.name (name_at columns primary.col.idx))) in
      (match indexed with
       | Some (idx, primary, bound2) -> select_indexed c tbl idx columns outs primary bound2
       | None -> select_scan c tbl columns outs cmps);
      List.map (name_at columns) outs)
  | Select _ | Project _ | Join _ | Outer_join _ | Set_op _ -> raise Invalid

let compile schema (t : Ast.t) =
  let c = { items = []; labels = 0 } in
  let columns, schema_change = match t.stmt with
    | Create_table tbl -> create_table c schema tbl t.text; [], true
    | Create_index x -> create_index c schema x t.text; [], true
    | Insert { table; values; _ } -> insert c schema table values; [], false
    | Select_stmt s -> select c schema s, false
    | Delete _ -> raise Invalid in
  { code = resolve c; columns; schema_change }
