(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Btree.mli *)

type t = { pager : Pager.t }
type tree = Table | Index
type level = Leaf | Internal

type cell =
  | Table_leaf of { key : int; data : Bytes.t }
  | Table_internal of { key : int; child : int }
  | Index_leaf of { key : int; pkey : int }
  | Index_internal of { key : int; pkey : int; child : int }

type node = {
  page : Pager.page;
  mutable tree : tree;
  mutable level : level;
  mutable free_offset : int;
  mutable n_cells : int;
  mutable cells_offset : int;
  mutable right_page : int;
}

exception Corrupt_header
exception Bad_node of int
exception Duplicate

let pager t = t.pager

let key = function Table_leaf c -> c.key | Table_internal c -> c.key | Index_leaf c -> c.key | Index_internal c -> c.key

let default_page_size = 1024

(* the page type byte (SQLite's) *)
let type_byte = function
  | Table, Internal -> 0x05 | Table, Leaf -> 0x0D | Index, Internal -> 0x02 | Index, Leaf -> 0x0A

let of_type_byte = function
  | 0x05 -> Table, Internal | 0x0D -> Table, Leaf | 0x02 -> Index, Internal | 0x0A -> Index, Leaf
  | b -> raise (Bad_node b)

(* page 1's node starts after the file's header *)
let base npage = if npage = 1 then 100 else 0
let header_size = function Internal -> 12 | Leaf -> 8

(* where the cell offsets start *)
let offsets (n : node) = base n.page.npage + header_size n.level

let cell_size = function
  | Table_internal _ -> 8
  | Table_leaf c -> 8 + Bytes.length c.data
  | Index_internal _ -> 16
  | Index_leaf _ -> 12

let free_space (n : node) = n.cells_offset - n.free_offset

let get_node t npage : node =
  let page = Pager.read_page t.pager npage in
  let d = page.data and b = base npage in
  let tree, level = of_type_byte (Char.code (Bytes.get d b)) in
  { page; tree; level; free_offset = Record.get2 d (b + 1); n_cells = Record.get2 d (b + 3); cells_offset = Record.get2 d (b + 5);
    right_page = (match level with Internal -> Record.get4 d (b + 8) | Leaf -> 0) }

let write_node t (n : node) =
  let d = n.page.data and b = base n.page.npage in
  Bytes.set d b (Char.chr (type_byte (n.tree, n.level)));
  Record.put2 d (b + 1) n.free_offset;
  Record.put2 d (b + 3) n.n_cells;
  Record.put2 d (b + 5) n.cells_offset;
  Bytes.set d (b + 7) '\000';
  (match n.level with Internal -> Record.put4 d (b + 8) n.right_page | Leaf -> ());
  Pager.write_page t.pager n.page

(* chidb's initEmptyNode: a new header on the page as it is, its old
 * cells left in what becomes free space *)
let init_empty_node t npage tree level =
  let page = Pager.read_page t.pager npage in
  write_node t { page; tree; level; n_cells = 0; cells_offset = Pager.page_size t.pager;
                 free_offset = base npage + header_size level; right_page = 0 }

let new_node t tree level =
  let npage = Pager.allocate t.pager in
  init_empty_node t npage tree level;
  npage

let get_cell (n : node) i : cell =
  let d = n.page.data in
  let off = Record.get2 d (offsets n + (2 * i)) in
  match n.tree, n.level with
  | Table, Internal -> Table_internal { child = Record.get4 d off; key = Record.get_varint32 d (off + 4) }
  | Table, Leaf ->
      let size = Record.get_varint32 d off in
      Table_leaf { key = Record.get_varint32 d (off + 4); data = Bytes.sub d (off + 8) size }
  | Index, Internal -> Index_internal { child = Record.get4 d off; key = Record.get4 d (off + 8); pkey = Record.get4 d (off + 12) }
  | Index, Leaf -> Index_leaf { key = Record.get4 d (off + 4); pkey = Record.get4 d (off + 8) }

(* the cell written below the others, and its offset at position i *)
let insert_cell (n : node) i (c : cell) =
  let d = n.page.data in
  let off = n.cells_offset - cell_size c in
  (match c with
   | Table_internal c -> Record.put4 d off c.child; Record.put_varint32 d (off + 4) c.key
   | Table_leaf c ->
       Record.put_varint32 d off (Bytes.length c.data);
       Record.put_varint32 d (off + 4) c.key;
       Bytes.blit c.data 0 d (off + 8) (Bytes.length c.data)
   | Index_internal c -> Record.put4 d off c.child; Record.put4 d (off + 8) c.key; Record.put4 d (off + 12) c.pkey
   | Index_leaf c -> Record.put4 d (off + 4) c.key; Record.put4 d (off + 8) c.pkey);
  n.cells_offset <- off;
  let arr = offsets n in
  for j = n.n_cells downto i + 1 do Record.put2 d (arr + (2 * j)) (Record.get2 d (arr + (2 * (j - 1)))) done;
  Record.put2 d (arr + (2 * i)) off;
  n.n_cells <- n.n_cells + 1;
  n.free_offset <- n.free_offset + 2

(* the first cell whose key is >= key, or n_cells *)
let find_position (n : node) k =
  let rec go i = if i < n.n_cells && key (get_cell n i) < k then go (i + 1) else i in
  go 0

(* the child to descend to, from position i *)
let child_at (n : node) i =
  if i = n.n_cells then n.right_page
  else match get_cell n i with
    | Table_internal c -> c.child
    | Index_internal c -> c.child
    | Table_leaf _ | Index_leaf _ -> raise (Bad_node (type_byte (n.tree, n.level)))

let rec find t npage k =
  let n = get_node t npage in
  match n.tree, n.level with
  | Table, Leaf ->
      let rec go i = if i >= n.n_cells then None else match get_cell n i with
        | Table_leaf c when c.key = k -> Some c.data
        | _ -> go (i + 1) in
      go 0
  | _, Internal | Index, Leaf -> find t (child_at n (find_position n k)) k

(* is there no room in n for the cell and its offset; the cell's size
 * is counted as n's page type has it, as chidb does (a leaf cell tested
 * against an internal node counts as an internal cell) *)
let full (n : node) c =
  let size = match n.tree, n.level, c with
    | Table, Leaf, Table_leaf c -> 8 + Bytes.length c.data
    | Table, Leaf, (Table_internal _ | Index_leaf _ | Index_internal _) -> 8
    | Table, Internal, _ -> 8
    | Index, Internal, _ -> 16
    | Index, Leaf, _ -> 12 in
  free_space n < size + 2

(* chidb's split: the child's lower half (its median too, for a leaf)
 * to a new page, the upper half kept on the child's page,
 * reinitialized in place, and the median promoted into the parent at
 * position i; the new page's number *)
let split t nparent nchild i =
  let child = get_node t nchild in
  let tree = child.tree and level = child.level in
  let cs = Array.init child.n_cells (get_cell child) in
  let m = Array.length cs / 2 in
  let old_right = child.right_page in
  let low = match level with Leaf -> m + 1 | Internal -> m in
  let nm = new_node t tree level in
  let mnode = get_node t nm in
  for j = 0 to low - 1 do insert_cell mnode j cs.(j) done;
  (match level, cs.(m) with
   | Internal, (Table_internal { child; _ } | Index_internal { child; _ }) -> mnode.right_page <- child
   | Internal, (Table_leaf _ | Index_leaf _) | Leaf, _ -> ());
  write_node t mnode;
  init_empty_node t nchild tree level;
  let upper = get_node t nchild in
  for j = m + 1 to Array.length cs - 1 do insert_cell upper (j - m - 1) cs.(j) done;
  (match level with Internal -> upper.right_page <- old_right | Leaf -> ());
  write_node t upper;
  let promoted = match cs.(m) with
    | Table_leaf { key; _ } | Table_internal { key; _ } -> Table_internal { key; child = nm }
    | Index_leaf { key; pkey } | Index_internal { key; pkey; _ } -> Index_internal { key; pkey; child = nm } in
  let parent = get_node t nparent in
  insert_cell parent i promoted;
  write_node t parent;
  nm

let rec insert_non_full t npage c =
  let n = get_node t npage in
  let pos = find_position n (key c) in
  match n.level with
  | Leaf ->
      if pos < n.n_cells && key (get_cell n pos) = key c then raise Duplicate;
      insert_cell n pos c;
      write_node t n
  | Internal ->
      let child = child_at n pos in
      let child =
        if full (get_node t child) c then begin
          ignore (split t npage child pos);
          (* the parent's cells changed: descend again *)
          let n = get_node t npage in
          child_at n (find_position n (key c))
        end
        else child
      in
      insert_non_full t child c

(* a full root is copied to a new page and split there, so that it
 * keeps its page number *)
let insert t nroot c =
  let root = get_node t nroot in
  if full root c then begin
    let tree = root.tree and level = root.level in
    let nc = new_node t tree level in
    let copy = get_node t nc and root = get_node t nroot in
    for i = 0 to root.n_cells - 1 do insert_cell copy i (get_cell root i) done;
    copy.right_page <- root.right_page;
    write_node t copy;
    init_empty_node t nroot tree Internal;
    let root = get_node t nroot in
    root.right_page <- nc;
    write_node t root;
    ignore (split t nroot nc 0)
  end;
  insert_non_full t nroot c

let insert_in_table t nroot k data = insert t nroot (Table_leaf { key = k; data })
let insert_in_index t nroot k pkey = insert t nroot (Index_leaf { key = k; pkey })

let rec collect t npage acc =
  let n = get_node t npage in
  match n.tree, n.level with
  | _, Leaf -> List.rev_append (List.init n.n_cells (get_cell n)) acc
  | Table, Internal ->
      collect t n.right_page
        (List.fold_left (fun acc i -> match get_cell n i with
           | Table_internal c -> collect t c.child acc
           | Table_leaf _ | Index_leaf _ | Index_internal _ -> acc) acc (List.init n.n_cells Fun.id))
  | Index, Internal ->
      collect t n.right_page
        (List.fold_left (fun acc i -> match get_cell n i with
           | Index_internal c as cell -> cell :: collect t c.child acc
           | Table_leaf _ | Table_internal _ | Index_leaf _ -> acc) acc (List.init n.n_cells Fun.id))

let cells t root = (get_node t root).tree, List.rev (collect t root [])

(* chidb's header for a new file; checked against for an old one *)
let header_ok (h : Bytes.t) =
  let b i = Char.code (Bytes.get h i) in
  Bytes.sub_string h 0 16 = "SQLite format 3\000"
  && b 18 = 1 && b 19 = 1 && b 20 = 0 && b 21 = 64 && b 22 = 32 && b 23 = 32
  && List.for_all (fun (off, v) -> Record.get4 h off = v)
       [ 24, 0; 32, 0; 36, 0; 40, 0; 44, 1; 48, 20000; 52, 0; 56, 1; 60, 0; 64, 0 ]

let open_file caps file =
  let pager = Pager.open_file caps file in
  let t = { pager } in
  (match Pager.read_header pager with
   | None ->
       Pager.set_page_size pager default_page_size;
       let n1 = Pager.allocate pager in
       let page1 = Pager.read_page pager n1 in
       Bytes.fill page1.data 0 default_page_size '\000';
       Bytes.blit_string "SQLite format 3\000" 0 page1.data 0 16;
       Record.put2 page1.data 16 default_page_size;
       List.iter (fun (off, v) -> Bytes.set page1.data off (Char.chr v)) [ 18, 1; 19, 1; 21, 64; 22, 32; 23, 32 ];
       List.iter (fun (off, v) -> Record.put4 page1.data off v) [ 44, 1; 48, 20000; 56, 1 ];
       Pager.write_page pager page1;
       init_empty_node t 1 Table Leaf
   | Some h ->
       if not (header_ok h) then (Pager.close pager; raise Corrupt_header);
       Pager.set_page_size pager (Record.get2 h 16));
  t

let close t = Pager.close t.pager
