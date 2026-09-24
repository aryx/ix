(* The pager: the database file as numbered pages of bytes.
 *
 * Pages are numbered from 1 and all have the same size (1,024 bytes
 * for a new file; an existing one says its size in its header). The
 * pager reads and writes whole pages, with no cache: every read goes
 * to the file, so a page read after a write sees it, as in chidb's
 * pager.c. A page is allocated by counting it; it exists in the file
 * once written, and a page read past the end of the file is zeros
 * (chidb's calloc and short fread).
 *
 *      file:  | page 1           | page 2 | page 3 | ...
 *             | header | node 1  |
 *               100 bytes
 *
 * References: SQLite's file format ("The Database File Format",
 * sqlite.org), whose page 1 header chidb keeps (checked, through
 * chidb's own file format page, docs/chidb-website/chidb/fileformat.html,
 * which says its format "is a subset of the SQLite file format"). *)

type t

(* a page's number, and its bytes, changed in place and written back *)
type page = { npage : int; data : Bytes.t }

(* a page number out of the file's range (chidb's CHIDB_EPAGENO) *)
exception Bad_page of int

(* the file, created if absent; its pages are counted once the page
 * size is known *)
val open_file : < Cap.open_in; Cap.open_out; .. > -> Fpath.t -> t

val set_page_size : t -> int -> unit
val page_size : t -> int

(* the first 100 bytes, or None if the file is shorter *)
val read_header : t -> Bytes.t option

(* a new page's number, one past the last *)
val allocate : t -> int

val read_page : t -> int -> page
val write_page : t -> page -> unit
val close : t -> unit
