(* Addresses, as ed.c's address() reads them, and the remembered
 * pattern they share with s and g.
 *
 *     .   $   3   /re/   ?re?   'a      dot, the last line, line 3, the next
 *                                       (previous) match, wrapping; a mark
 *     a+n  a-n  a+  a-  +  -  ^         relative; a lone + or - is 1, and
 *                                       they add up (-- is .-2); ^ is -
 *
 * An address is read and evaluated at once: a search starts from
 * dot, and a pattern read becomes the remembered one, which // (an
 * empty pattern) means. So there is no syntax tree: [address] returns
 * a line number, or None when there is no address at all.
 *
 *     with dot = 2 in x1 y x2:   "/x/"  -> 3    "?x?" -> 1    "$-" -> 2
 *                                "'a" with no mark a -> Error "" *)

type t = {
  input : Input.t;
  text : Text.t;
  mutable pattern : Regex.t option;   (* the remembered pattern *)
}

(* [read_pattern t delim]: the pattern up to [delim] or the end of the
 * line, compiled and remembered; an empty one is the remembered one
 * (ed.c's compile) *)
val read_pattern : t -> int -> unit

(* [matches t n]: line n (not 0) has a match of the remembered pattern *)
val matches : t -> int -> bool

val address : t -> int option

(* ed.c's commands() prologue: the addresses before a command, joined
 * by , or ; (which sets dot first), and the defaults: a missing first
 * address before , or ; is 1, a missing last one after them $, and no
 * address at all is dot.
 *
 *     "2,4p"  -> { addr1 = 2; addr2 = 4; given = true; cmd = 'p' }
 *     "p"     -> { addr1 = dot; addr2 = dot; given = false; ... } *)
(* old: an int, ',' or ';', or a newline for none *)
type sep = Start | Comma | Semicolon

type range = {
  addr1 : int;
  addr2 : int;
  given : bool;          (* was there an address *)
  last : int option;     (* the last address read, for a newline command *)
  lastsep : sep;         (* the last separator, Start if none *)
  cmd : int;             (* the character after them *)
}

val range : t -> range
