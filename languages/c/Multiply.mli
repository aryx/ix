(* A multiplication by a constant as shifts, adds and subtracts (5c's
 * mul.c): at most three operations, found by a search, with a table of
 * hints for the numbers the search misses. arm's barrel shifter makes
 * each operation one instruction.
 *
 * References: R. Bernstein, "Multiplication by integer constants"
 * (Software -- Practice and Experience, 1986), the classic statement of
 * the problem, as a search for the cheapest chain. *)

(* the program of v's multiplication, if one is short enough *)
val mulcon0 : int -> string option
