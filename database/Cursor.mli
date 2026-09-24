(* A cursor: a position in a B-tree, moved in key order.
 *
 * chidb's cursor is a snapshot: opening it reads the whole tree into
 * an array of its entries in key order, and moving it moves along the
 * array (an index's internal entries between their children's):
 *
 *      entries:  [ (1, row) (2, row) (3, row) ... ]      pos: -1, then 0 .. n-1
 *
 * Opening costs a read of the tree, and an insertion made after the
 * opening is not seen; chidb's statements never read a tree they
 * write, so that is never visible. The textbook cursor is a stack of
 * (page, cell) positions from the root, moved in place (the tutorial,
 * §6, and its exercise 1). Seeks are linear, as chidb's are. *)

type entry =
  | Row of { key : int; data : Bytes.t }      (* a table's: primary key, record *)
  | Entry of { key : int; pkey : int }        (* an index's: value, primary key *)

type t

(* the comparisons a seek positions by: the first entry = k, > k, >= k,
 * or the last < k, <= k *)
type seek = Eq | Gt | Ge | Lt | Le

val open_ : Btree.t -> int -> t

(* the tree's root page *)
val root : t -> int

(* to the first entry; false (and unpositioned) if there is none *)
val rewind : t -> bool

(* to the next or previous entry; false, and unmoved, at an end *)
val next : t -> bool
val prev : t -> bool

(* false, and unmoved, if no entry qualifies *)
val seek : t -> seek -> int -> bool

(* the current entry; Invalid_argument if unpositioned *)
val current : t -> entry
