(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny relational database, in one file, whose query language is the
 * relational algebra itself. mini-chidb (database/) is chidb, faithfully:
 * SQL compiled to a register machine over B-trees of fixed pages,
 * changed in place. This keeps the ideas and takes the other roads:
 *
 *     table books (id int key, title text, author text, year int)
 *     insert books (1, "SICP", "Abelson", 1985), (2, "TAOCP", "Knuth", 1968)
 *     index books year
 *     books | where year > 1980 | select title, year | sort year desc
 *     books | join authors | group country (n = count, newest = max year)
 *     books | where year < 1970 | set year = year + 1
 *     books | where author = "Knuth" | delete
 *     explain books | where year > 1980 | take 2
 *
 * - {b A query is a pipeline of the algebra's operators}, read left to
 *   right as a Unix pipe: a table, then where (sigma), select (pi,
 *   with computed columns), join (the natural join), group (with count,
 *   sum, min, max), sort, take. SQL's SELECT ... FROM ... WHERE is this
 *   pipeline written in a fixed order; here the order is the user's,
 *   and each stage's columns are the previous stage's output.
 * - {b The tree is copy-on-write}: a node, once written, never changes.
 *   An insertion writes the path from a new leaf to a new root, at the
 *   end of the file, and a statement commits by writing its new
 *   catalog there and its offset in the file's header, one small write.
 *   So every statement is atomic (a crash before the header's write
 *   leaves the previous state whole), nodes can be cached without
 *   invalidation, and readers of an old root would see a consistent old
 *   database (not used here). The price: the file grows; nothing is
 *   reused, as in an append-only log. Nodes are marshalled OCaml values
 *   of any size, not fixed pages: fixed pages are for changing in place.
 * - {b Evaluation pulls rows through the stages} (a Seq per stage, the
 *   iterator model), the first where stage choosing an access path by
 *   its shape: a key range on the table, a range on an index, or a
 *   scan; explain prints the choice. Joins hash the right table.
 * - Keys are values, lists of them compared lexicographically: a
 *   table's tree is keyed by [key column], an index's by [value; key],
 *   so an index entry is unique and a range on the value is a range on
 *   the tree. Deletion removes the entry and does not rebalance: a
 *   node may be left underfull, even empty, and searches stay right.
 *
 * Kept from chidb: tables with a key, int and text columns, indexes,
 * joins, a file that outlives the program. Added: delete, update
 * (set), group and the aggregates, sort, take, computed columns, and
 * the atomic statement. Dropped: SQL, NULL, the machine and its
 * programs, the 1,024-byte pages and SQLite's file format.
 *
 * The test: TinyDatabase_test.sh runs pipelines through it and the
 * equivalent SQL through SQLite (Python's sqlite3), rows compared.
 *
 * Exercises, each cheap because nodes never change:
 * - transactions of several statements: begin ... commit, the header
 *   written only at commit (and rollback: forget the catalog in
 *   memory); about 10 lines, since a statement is already one;
 * - time travel: each catalog also records the offset of the one it
 *   replaces, and books @ 3 reads the table as it was three commits
 *   ago; the old roots are all still in the file;
 * - compaction: copy the live trees into a new file, then rename it
 *   over the old one; the rename is atomic too, and the file stops
 *   growing forever;
 * - readers beside a writer: a reader keeps the root it started with,
 *   a snapshot, with no lock (LMDB's design);
 * - rebalancing on delete: merge an underfull node with a sibling.
 *
 * Usage: tiny-db file.db -- statements on standard input, one a
 * line, # for comments
 *
 * References: R. Bayer and E. McCreight, "Organization and Maintenance
 * of Large Ordered Indices" (Acta Informatica, 1972; from memory), the
 * B-tree; O. Rodeh, "B-trees, Shadowing, and Clones" (ACM Transactions
 * on Storage, 2008; from memory), copy-on-write B-trees, the design of
 * LMDB and btrfs; G. Graefe, "Volcano -- An Extensible and Parallel
 * Query Evaluation System" (IEEE TKDE, 1994; from memory), the
 * iterator model; E. F. Codd, "A Relational Model of Data for Large
 * Shared Data Banks" (CACM, 1970; from memory), the algebra. *)

exception Error of string

let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

(*****************************************************************************)
(* Values *)
(*****************************************************************************)

type value = Int of int | Text of string
type typ = TInt | TText
type row = value array

let show = function Int n -> string_of_int n | Text s -> s
let type_of = function Int _ -> TInt | Text _ -> TText
let truth = function Int 0 -> false | Int _ | Text _ -> true
let of_bool b = Int (if b then 1 else 0)

(*****************************************************************************)
(* The file: blobs appended, and a header that commits *)
(*****************************************************************************)

(* the header: a magic string and the offset of the committed catalog *)
let magic = "tinydb1\n"

type key = value list

(* children.(i) holds the keys below seps.(i) (and at or above
 * seps.(i - 1)); the last child the rest *)
type node = Leaf of (key * row) array | Inner of key array * int array

type file = { fd : Unix.file_descr; cache : (int, node) Hashtbl.t }

let read_at f off len =
  let b = Bytes.create len in
  ignore (Unix.lseek f.fd off Unix.SEEK_SET);
  let rec go n = if n < len then match Unix.read f.fd b n (len - n) with 0 -> error "truncated file" | k -> go (n + k) in
  go 0;
  b

let write_at f off s = ignore (Unix.lseek f.fd off Unix.SEEK_SET); ignore (Unix.write_substring f.fd s 0 (String.length s))

(* a value at the end of the file: its length, then its bytes *)
let append f v =
  let s = Marshal.to_string v [] in
  let off = Unix.lseek f.fd 0 Unix.SEEK_END in
  let len = Bytes.create 8 in
  Bytes.set_int64_be len 0 (Int64.of_int (String.length s));
  write_at f off (Bytes.to_string len ^ s);
  off

let load f off = Marshal.from_bytes (read_at f (off + 8) (Int64.to_int (Bytes.get_int64_be (read_at f off 8) 0))) 0

let node f off =
  match Hashtbl.find_opt f.cache off with
  | Some n -> n
  | None -> let n : node = load f off in Hashtbl.replace f.cache off n; n

let write f (n : node) = let off = append f n in Hashtbl.replace f.cache off n; off

(*****************************************************************************)
(* Copy-on-write B-trees *)
(*****************************************************************************)

let max_entries = 16

let empty_tree f = write f (Leaf [||])

(* the child for a key: the number of separators at or below it *)
let child seps k = let rec go i = if i < Array.length seps && seps.(i) <= k then go (i + 1) else i in go 0

(* the entries from [from] on, in key order, read as they are pulled *)
let rec scan f off (from : key option) : (key * row) Seq.t =
  match node f off with
  | Leaf es -> Seq.drop_while (fun (k, _) -> match from with Some lo -> k < lo | None -> false) (Array.to_seq es)
  | Inner (seps, kids) ->
      let start = match from with Some lo -> child seps lo | None -> 0 in
      Seq.concat_map (fun i -> scan f kids.(i) (if i = start then from else None)) (Seq.init (Array.length kids - start) (( + ) start))

let find f off k = match scan f off (Some k) () with Seq.Cons ((k', r), _) when k' = k -> Some r | _ -> None

let insert_at a i x = Array.concat [ Array.sub a 0 i; [| x |]; Array.sub a i (Array.length a - i) ]

(* the new subtree: one node, or two and the separator between *)
let rec ins f off k r =
  match node f off with
  | Leaf es ->
      let i = let rec go i = if i < Array.length es && fst es.(i) < k then go (i + 1) else i in go 0 in
      if i < Array.length es && fst es.(i) = k then error "duplicate key %s" (String.concat ", " (List.map show k));
      let es = insert_at es i (k, r) in
      if Array.length es <= max_entries then `One (write f (Leaf es))
      else
        let m = Array.length es / 2 in
        `Two (write f (Leaf (Array.sub es 0 m)), fst es.(m), write f (Leaf (Array.sub es m (Array.length es - m))))
  | Inner (seps, kids) -> (
      let i = child seps k in
      match ins f kids.(i) k r with
      | `One c -> let kids = Array.copy kids in kids.(i) <- c; `One (write f (Inner (seps, kids)))
      | `Two (a, sep, b) ->
          let seps = insert_at seps i sep and kids = insert_at kids i a in
          kids.(i + 1) <- b;
          if Array.length kids <= max_entries then `One (write f (Inner (seps, kids)))
          else
            (* the middle separator goes up; each half keeps its children *)
            let m = Array.length seps / 2 in
            `Two (write f (Inner (Array.sub seps 0 m, Array.sub kids 0 (m + 1))), seps.(m),
                  write f (Inner (Array.sub seps (m + 1) (Array.length seps - m - 1), Array.sub kids (m + 1) (Array.length kids - m - 1)))))

let insert f root k r =
  match ins f root k r with `One root -> root | `Two (a, sep, b) -> write f (Inner ([| sep |], [| a; b |]))

(* no rebalancing: an underfull node, even an empty leaf, is still right *)
let rec delete f off k =
  match node f off with
  | Leaf es -> write f (Leaf (Array.of_list (List.filter (fun (k', _) -> k' <> k) (Array.to_list es))))
  | Inner (seps, kids) -> let i = child seps k and kids = Array.copy kids in kids.(i) <- delete f kids.(i) k; write f (Inner (seps, kids))

(*****************************************************************************)
(* The catalog *)
(*****************************************************************************)

type table = {
  name : string;
  cols : (string * typ) list;
  key : int;                       (* the key column's position *)
  root : int;
  indexes : (string * int) list;   (* a column, its index's root *)
}

type db = { file : file; mutable tables : table list }

let open_db (_ : < Cap.open_in; Cap.open_out; .. >) path =
  let fd = Unix.openfile path [ Unix.O_RDWR; Unix.O_CREAT ] 0o644 in
  let file = { fd; cache = Hashtbl.create 256 } in
  if (Unix.fstat fd).st_size < 16 then begin
    write_at file 0 (magic ^ String.make 8 '\000');
    { file; tables = [] }
  end
  else if Bytes.to_string (read_at file 0 8) <> magic then error "%s: not a mini-chidb file" path
  else
    let off = Int64.to_int (Bytes.get_int64_be (read_at file 8 8) 0) in
    { file; tables = (if off = 0 then [] else load file off) }

(* the statement's changes made durable: the new catalog, then the
 * header pointing at it *)
let commit db tables =
  let off = append db.file tables in
  let h = Bytes.create 8 in
  Bytes.set_int64_be h 0 (Int64.of_int off);
  write_at db.file 8 (Bytes.to_string h);
  db.tables <- tables

let table db name = match List.find_opt (fun t -> t.name = name) db.tables with Some t -> t | None -> error "no table %s" name

let replace db (t : table) = List.map (fun t' -> if t'.name = t.name then t else t') db.tables

(* a row in, its key in its table and in each index *)
let add f (t : table) (r : row) =
  let k = r.(t.key) in
  let pos c = let rec go i = function (n, _) :: rest -> if n = c then i else go (i + 1) rest | [] -> 0 in go 0 t.cols in
  { t with root = insert f t.root [ k ] r;
           indexes = List.map (fun (c, root) -> c, insert f root [ r.(pos c); k ] [||]) t.indexes }

let remove f (t : table) (r : row) =
  let k = r.(t.key) in
  let pos c = let rec go i = function (n, _) :: rest -> if n = c then i else go (i + 1) rest | [] -> 0 in go 0 t.cols in
  { t with root = delete f t.root [ k ]; indexes = List.map (fun (c, root) -> c, delete f root [ r.(pos c); k ]) t.indexes }

(*****************************************************************************)
(* The language *)
(*****************************************************************************)

type token = Name of string | Num of int | Str of string | Sym of string

let tokens (s : string) : token list =
  let n = String.length s in
  let rec go i acc =
    if i >= n || s.[i] = '#' then List.rev acc
    else match s.[i] with
      | ' ' | '\t' | '\r' -> go (i + 1) acc
      | 'a' .. 'z' | 'A' .. 'Z' | '_' ->
          let j = ref i in
          while !j < n && (match s.[!j] with 'a' .. 'z' | 'A' .. 'Z' | '_' | '0' .. '9' -> true | _ -> false) do incr j done;
          go !j (Name (String.sub s i (!j - i)) :: acc)
      | '0' .. '9' ->
          let j = ref i in
          while !j < n && s.[!j] >= '0' && s.[!j] <= '9' do incr j done;
          go !j (Num (int_of_string (String.sub s i (!j - i))) :: acc)
      | ('"' | '\'') as q ->
          let j = match String.index_from_opt s (i + 1) q with Some j -> j | None -> error "unclosed string" in
          go (j + 1) (Str (String.sub s (i + 1) (j - i - 1)) :: acc)
      | '!' | '<' | '>' when i + 1 < n && s.[i + 1] = '=' -> go (i + 2) (Sym (String.sub s i 2) :: acc)
      | c -> go (i + 1) (Sym (String.make 1 c) :: acc)
  in
  go 0 []

type binop = Add | Sub | Mul | Div | Eq | Ne | Lt | Le | Gt | Ge | And | Or

type expr = Lit of value | Col of string | Bin of binop * expr * expr | Not of expr | Neg of expr

type agg = Count | Sum of string | Min of string | Max of string

type stage =
  | Where of expr
  | Select of (string * expr) list
  | Join of string
  | Group of string list * (string * agg) list
  | Sort of (string * bool) list      (* true: descending *)
  | Take of int

(* the statements; a query's last stage may be delete or set, on the
 * rows of its table the stages before it (where only) kept *)
type stmt =
  | Create of string * (string * typ * bool) list
  | Insert of string * value list list
  | Index of string * string
  | Query of bool * string * stage list          (* explain? *)
  | Delete of string * stage list
  | Update of string * stage list * (string * expr) list

(* a parser over a token list, by recursive descent: the grammar is an
 * expression's precedence and a stage's few forms *)
let parse (ts : token list) : stmt =
  let ts = ref ts in
  let peek () = match !ts with t :: _ -> Some t | [] -> None in
  let next () = match !ts with t :: rest -> ts := rest; t | [] -> error "unexpected end" in
  let expect t = if next () <> t then error "syntax error" in
  let name () = match next () with Name n -> n | _ -> error "a name expected" in
  let accept t = if peek () = Some t then (ignore (next ()); true) else false in
  let rec list f = let x = f () in if accept (Sym ",") then x :: list f else [ x ] in
  let literal () = match next () with
    | Num n -> Int n | Str s -> Text s | Sym "-" -> (match next () with Num n -> Int (- n) | _ -> error "a number expected")
    | _ -> error "a value expected" in
  let rec expr () = binary [ [ Name "or", Or ]; [ Name "and", And ] ] not_
  and binary levels last =
    match levels with
    | [] -> last ()
    | ops :: rest ->
        let rec loop l = match peek () with
          | Some t when List.mem_assoc t ops -> ignore (next ()); loop (Bin (List.assoc t ops, l, binary rest last))
          | _ -> l in
        loop (binary rest last)
  and not_ () = if accept (Name "not") then Not (not_ ()) else comparison ()
  and comparison () =
    let l = binary [ [ Sym "+", Add; Sym "-", Sub ]; [ Sym "*", Mul; Sym "/", Div ] ] atom in
    match peek () with
    | Some (Sym ("=" | "!=" | "<" | "<=" | ">" | ">=" as op)) ->
        ignore (next ());
        Bin (List.assoc op [ "=", Eq; "!=", Ne; "<", Lt; "<=", Le; ">", Gt; ">=", Ge ], l, binary [ [ Sym "+", Add; Sym "-", Sub ]; [ Sym "*", Mul; Sym "/", Div ] ] atom)
    | _ -> l
  and atom () = match next () with
    | Num n -> Lit (Int n)
    | Str s -> Lit (Text s)
    | Name c -> Col c
    | Sym "-" -> Neg (atom ())
    | Sym "(" -> let e = expr () in expect (Sym ")"); e
    | _ -> error "syntax error" in
  let item () = let n = name () in if accept (Sym "=") then n, expr () else n, Col n in
  let aggregate () =
    let n = name () in
    expect (Sym "=");
    n, (match name () with "count" -> Count | "sum" -> Sum (name ()) | "min" -> Min (name ()) | "max" -> Max (name ()) | a -> error "no aggregate %s" a) in
  let rec stages () =
    if not (accept (Sym "|")) then []
    else match name () with
      | "where" -> let e = expr () in Where e :: stages ()
      | "select" -> let items = list item in Select items :: stages ()
      | "join" -> let t = name () in Join t :: stages ()
      | "group" ->
          let rec keys () = match peek () with Some (Name n) -> ignore (next ()); n :: keys () | _ -> [] in
          let ks = keys () in
          expect (Sym "(");
          let aggs = list aggregate in
          expect (Sym ")");
          Group (ks, aggs) :: stages ()
      | "sort" -> let ks = list (fun () -> let n = name () in n, accept (Name "desc")) in Sort ks :: stages ()
      | "take" -> (match next () with Num n -> Take n :: stages () | _ -> error "take: a number expected")
      | "delete" -> [ Take (-1) ]     (* a marker, taken apart below *)
      | "set" -> let items = list item in [ Select ((" set", Lit (Int 0)) :: items) ]
      | s -> error "no stage %s" s in
  let query explain =
    let t = name () in
    let ss = stages () in
    match List.rev ss with
    | Take -1 :: rest -> Delete (t, List.rev rest)
    | Select ((" set", _) :: items) :: rest -> Update (t, List.rev rest, items)
    | _ -> Query (explain, t, ss) in
  let stmt = match !ts with
    | Name "table" :: _ ->
        ignore (next ());
        let t = name () in
        expect (Sym "(");
        let cols = list (fun () ->
          let c = name () in
          let typ = match name () with "int" -> TInt | "text" -> TText | ty -> error "no type %s" ty in
          c, typ, accept (Name "key")) in
        expect (Sym ")");
        Create (t, cols)
    | Name "insert" :: _ ->
        ignore (next ());
        let t = name () in
        Insert (t, list (fun () -> expect (Sym "("); let vs = list literal in expect (Sym ")"); vs))
    | Name "index" :: _ -> ignore (next ()); let t = name () in Index (t, name ())
    | Name "explain" :: _ -> ignore (next ()); query true
    | _ -> query false in
  if !ts <> [] then error "syntax error";
  stmt

(*****************************************************************************)
(* Evaluation: the stages as iterators *)
(*****************************************************************************)

(* an expression compiled against its columns *)
let rec compile (cols : string list) (e : expr) : row -> value =
  match e with
  | Lit v -> fun _ -> v
  | Col c ->
      let rec pos i = function x :: rest -> if x = c then i else pos (i + 1) rest | [] -> error "no column %s" c in
      let i = pos 0 cols in
      fun r -> r.(i)
  | Not e -> let f = compile cols e in fun r -> of_bool (not (truth (f r)))
  | Neg e -> let f = compile cols e in fun r -> (match f r with Int n -> Int (- n) | Text _ -> error "- of a text")
  | Bin (op, a, b) ->
      let fa = compile cols a and fb = compile cols b in
      fun r ->
        let x = fa r and y = fb r in
        match op, x, y with
        | And, _, _ -> of_bool (truth x && truth y)
        | Or, _, _ -> of_bool (truth x || truth y)
        | Eq, _, _ -> of_bool (x = y)
        | Ne, _, _ -> of_bool (x <> y)
        | Lt, _, _ -> of_bool (x < y)
        | Le, _, _ -> of_bool (x <= y)
        | Gt, _, _ -> of_bool (x > y)
        | Ge, _, _ -> of_bool (x >= y)
        | Add, Int m, Int n -> Int (m + n)
        | Sub, Int m, Int n -> Int (m - n)
        | Mul, Int m, Int n -> Int (m * n)
        | Div, Int _, Int 0 -> error "division by zero"
        | Div, Int m, Int n -> Int (m / n)
        | (Add | Sub | Mul | Div), _, _ -> error "arithmetic on a text"

let names (t : table) = List.map fst t.cols

(* the access path for a table and its first where: a range on the key
 * or on an index, from a conjunct column op literal; or a scan. The
 * where still filters every row, so a range only has to contain the
 * rows wanted: from the value for > >= =, up to it for < <= = *)
type access = Scan | Range of string option * value * binop   (* an index's column, or the key *)

let rec conjuncts = function Bin (And, a, b) -> conjuncts a @ conjuncts b | e -> [ e ]

let plan (t : table) (stages : stage list) =
  let key = fst (List.nth t.cols t.key) in
  let usable = function
    | Bin ((Eq | Lt | Le | Gt | Ge) as op, Col c, Lit v) -> Some (c, v, op)
    | Bin ((Eq | Lt | Le | Gt | Ge) as op, Lit v, Col c) ->
        Some (c, v, match op with Lt -> Gt | Le -> Ge | Gt -> Lt | Ge -> Le | o -> o)
    | _ -> None in
  match stages with
  | Where e :: _ -> (
      let cs = List.filter_map usable (conjuncts e) in
      match List.find_opt (fun (c, _, _) -> c = key) cs with
      | Some (_, v, op) -> Range (None, v, op)
      | None -> (
          match List.find_opt (fun (c, _, _) -> List.mem_assoc c t.indexes) cs with
          | Some (c, v, op) -> Range (Some c, v, op)
          | None -> Scan))
  | _ -> Scan

let show_access (t : table) = function
  | Scan -> Printf.sprintf "scan %s" t.name
  | Range (c, v, op) ->
      Printf.sprintf "range %s.%s %s %s%s" t.name (match c with Some c -> c | None -> fst (List.nth t.cols t.key))
        (List.assoc op [ Eq, "="; Lt, "<"; Le, "<="; Gt, ">"; Ge, ">=" ]) (show v) (if c = None then " (key)" else " (index)")

let rows db (t : table) (a : access) : row Seq.t =
  let f = db.file in
  let bounded v op (k : key) = match op, k with (Eq | Lt | Le), v' :: _ -> v' <= v | _ -> true in
  let from v op = match op with Eq | Gt | Ge -> Some [ v ] | _ -> None in
  match a with
  | Scan -> Seq.map snd (scan f t.root None)
  | Range (None, v, op) -> Seq.map snd (Seq.take_while (fun (k, _) -> bounded v op k) (scan f t.root (from v op)))
  | Range (Some c, v, op) ->
      Seq.take_while (fun (k, _) -> bounded v op k) (scan f (List.assoc c t.indexes) (from v op))
      |> Seq.filter_map (fun (k, _) -> match k with [ _; pk ] -> find f t.root [ pk ] | _ -> None)

(* a stage: its output columns and rows, from its input's *)
let stage db (cols, (rs : row Seq.t)) = function
  | Where e -> let f = compile cols e in cols, Seq.filter (fun r -> truth (f r)) rs
  | Select items ->
      let fs = List.map (fun (_, e) -> compile cols e) items in
      List.map fst items, Seq.map (fun r -> Array.of_list (List.map (fun f -> f r) fs)) rs
  | Join name ->
      (* a hash join: the right table in a table by the shared columns *)
      let t = table db name in
      let shared = List.filter (fun c -> List.mem c cols) (names t) in
      let pos cs c = let rec go i = function x :: rest -> if x = c then i else go (i + 1) rest | [] -> -1 in go 0 cs in
      let h = Hashtbl.create 64 in
      Seq.iter (fun r -> Hashtbl.add h (List.map (fun c -> r.(pos (names t) c)) shared) r) (rows db t Scan);
      let rest = List.filter (fun c -> not (List.mem c shared)) (names t) in
      cols @ rest,
      Seq.concat_map (fun l ->
        let k = List.map (fun c -> l.(pos cols c)) shared in
        List.to_seq (List.rev_map (fun r -> Array.append l (Array.of_list (List.map (fun c -> r.(pos (names t) c)) rest))) (Hashtbl.find_all h k))) rs
  | Group (keys, aggs) ->
      let key = List.map (fun k -> compile cols (Col k)) keys in
      let groups = Hashtbl.create 64 and order = ref [] in
      Seq.iter (fun r ->
        let k = List.map (fun f -> f r) key in
        if not (Hashtbl.mem groups k) then order := k :: !order;
        Hashtbl.replace groups k (r :: Option.value (Hashtbl.find_opt groups k) ~default:[])) rs;
      let fold (a : agg) (g : row list) =
        let col c = let f = compile cols (Col c) in List.map f g in
        let ints c = List.map (function Int n -> n | Text _ -> error "sum of a text") (col c) in
        match a with
        | Count -> Int (List.length g)
        | Sum c -> Int (List.fold_left ( + ) 0 (ints c))
        | Min c -> List.fold_left min (List.hd (col c)) (col c)
        | Max c -> List.fold_left max (List.hd (col c)) (col c) in
      keys @ List.map fst aggs,
      List.to_seq (List.rev_map (fun k -> let g = Hashtbl.find groups k in Array.of_list (k @ List.map (fun (_, a) -> fold a g) aggs)) !order)
  | Sort ks ->
      let fs = List.map (fun (c, desc) -> compile cols (Col c), desc) ks in
      let cmp a b = List.fold_left (fun acc (f, desc) -> if acc <> 0 then acc else (if desc then -1 else 1) * compare (f a) (f b)) 0 fs in
      cols, List.to_seq (List.stable_sort cmp (List.of_seq rs))
  | Take n -> cols, Seq.take n rs

let run_query db t stages =
  let a = plan t stages in
  a, List.fold_left (stage db) (names t, rows db t a) stages

(*****************************************************************************)
(* The statements *)
(*****************************************************************************)

let print (_ : < Cap.stdout; .. >) s = print_string s

let exec caps db (s : stmt) =
  let f = db.file in
  match s with
  | Create (name, cols) ->
      if List.exists (fun t -> t.name = name) db.tables then error "table %s exists" name;
      let key = match List.filteri (fun _ (_, _, k) -> k) cols with
        | [ _ ] -> let rec go i = function (_, _, true) :: _ -> i | _ :: rest -> go (i + 1) rest | [] -> 0 in go 0 cols
        | [] -> 0 | _ -> error "one key" in
      commit db (db.tables @ [ { name; cols = List.map (fun (c, ty, _) -> c, ty) cols; key; root = empty_tree f; indexes = [] } ])
  | Insert (name, tuples) ->
      let t = table db name in
      let t = List.fold_left (fun t vs ->
        if List.length vs <> List.length t.cols then error "%s has %d columns" name (List.length t.cols);
        List.iter2 (fun v (c, ty) -> if type_of v <> ty then error "%s: a %s" c (if ty = TInt then "int" else "text")) vs t.cols;
        add f t (Array.of_list vs)) t tuples in
      commit db (replace db t)
  | Index (name, c) ->
      let t = table db name in
      if not (List.mem_assoc c t.cols) then error "no column %s" c;
      if List.mem_assoc c t.indexes then error "index on %s exists" c;
      let pos = let rec go i = function (n, _) :: rest -> if n = c then i else go (i + 1) rest | [] -> 0 in go 0 t.cols in
      let root = Seq.fold_left (fun root r -> insert f root [ r.(pos); r.(t.key) ] [||]) (empty_tree f) (rows db t Scan) in
      commit db (replace db { t with indexes = t.indexes @ [ c, root ] })
  | Query (explain, name, stages) ->
      let t = table db name in
      let a, (_, rs) = run_query db t stages in
      if explain then
        print caps (String.concat " | " (show_access t a :: List.map (function
          | Where _ -> "where" | Select _ -> "select" | Join t -> "hash join " ^ t | Group _ -> "group"
          | Sort _ -> "sort" | Take n -> "take " ^ string_of_int n) stages) ^ "\n")
      else Seq.iter (fun r -> print caps (String.concat "|" (Array.to_list (Array.map show r)) ^ "\n")) rs
  | Delete (name, stages) | Update (name, stages, _) ->
      let t = table db name in
      if List.exists (function Where _ -> false | _ -> true) stages then error "only where before delete or set";
      (* the rows first, then the changes: the iterators read the old tree *)
      let _, (_, rs) = run_query db t stages in
      let rs = List.of_seq rs in
      let t = List.fold_left (remove f) t rs in
      let t = match s with
        | Update (_, _, items) ->
            let fs = List.map (fun (c, e) ->
              let rec go i = function (n, _) :: rest -> if n = c then i else go (i + 1) rest | [] -> error "no column %s" c in
              go 0 t.cols, compile (names t) e) items in
            List.fold_left (fun t r ->
              let r' = Array.copy r in
              List.iter (fun (i, e) -> r'.(i) <- e r) fs;
              add f t r') t rs
        | _ -> t in
      commit db (replace db t)

let main (caps : < Cap.argv; Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr; .. >) =
  match Array.to_list (CapSys.argv caps) with
  | [ _; path ] ->
      let db = open_db caps path in
      let rec loop n =
        match In_channel.input_line stdin with
        | None -> 0
        | Some line ->
            (try match tokens line with [] -> () | ts -> exec caps db (parse ts)
             with Error m -> flush stdout; prerr_endline (Printf.sprintf "tiny-db: line %d: %s" n m));
            loop (n + 1)
      in
      let code = loop 1 in
      flush stdout;
      code
  | _ -> prerr_endline "usage: tiny-db file.db"; 1

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
