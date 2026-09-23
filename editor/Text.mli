(* The buffer: numbered lines, a current line (dot) and a last one.
 *
 *     index   0      1          2           3        ($ = dol = 3)
 *             (0)   "int x;"   "int y;"    "}"
 *                               ^ dot = 2
 *
 * Line 0 is not a line: it is where 0a appends, before the first. An
 * empty buffer has dol = 0 and dot = 0.
 *
 * {b A line has an identity.} ed.c keeps the text in a temporary file
 * and the buffer as offsets into it, stealing the low bit of each for
 * g's marks. Here a line is a record in memory, and the record is the
 * line: a mark (k) holds it, so it follows its line through a move and
 * is gone with it after a delete; [global] is g's mark; and s makes a
 * new record, moving the old one's marks to it and keeping both for u.
 *
 *     let t = create () in
 *     append t 0 [ "x1"; "y"; "x2" ];      dol t = 3, dot t = 3
 *     mark t 'a' 2;  move t 1 2 3;          lines: x2 x1 y
 *     find_mark t 'a' = Some 3              the mark followed y *)

type line = { text : string; mutable global : bool }

type t

val create : unit -> t

val dol : t -> int
val dot : t -> int
val set_dot : t -> int -> unit

(* [changed]: modified since the last write, for q and e *)
val changed : t -> bool
val set_changed : t -> bool -> unit

val get : t -> int -> line
val text : t -> int -> string

(* [append t n texts]: new lines after line n; dot the last of them (n
 * when none); the number appended *)
val append : t -> int -> string list -> int

(* [delete t a b]: lines a..b; dot the line after, or the new last *)
val delete : t -> int -> int -> unit

(* [replace t n line]: line n is now [line] (s, j, u); not a change by
 * itself, since u is not one for ed.c *)
val replace : t -> int -> line -> unit

(* empty again, marks and undo forgotten (e) *)
val clear : t -> unit

(* [move t a b n]: lines a..b after line n (outside a..b); dot the last
 * moved *)
val move : t -> int -> int -> int -> unit

(* [delete_global t]: every line with [global] set, in one pass (g/re/d) *)
val delete_global : t -> unit

(* marks: k, 'x; [find_mark] None when the line is gone *)
val mark : t -> char -> int -> unit
val find_mark : t -> char -> int option

(* [renamed t old new]: the marks on [old] now on [new] (s) *)
val renamed : t -> line -> line -> unit

(* the undo pair of the last s: the line before, the line after *)
val undo : t -> (line * line) option
val set_undo : t -> (line * line) option -> unit

(* [index t line]: where [line] is, if it still is *)
val index : t -> line -> int option
