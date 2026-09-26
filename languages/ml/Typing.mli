(* Types inferred, then forgotten (plan_ml.md, decision 4; the
 * tutorial's section 6). Hindley-Milner's algorithm over Scope's tree:
 * type variables are cells, unified in place (union-find); a let's
 * variables deeper than its level are generalized (Rémy's levels, as
 * OCaml's), and only a value's (Wright's value restriction); an
 * abbreviation is expanded when two types' heads differ. A string
 * where Printf expects a format is typed by its conversions (%d an int,
 * %s a string, %a a printer and its argument...), the one special
 * case of ocaml-light's checker.
 *
 * Nothing after this pass reads a type: Lower compiles the tree it
 * checked. So a program ocaml-light accepts compiles without it
 * (-unsafe-types), and the tests compare what it accepts, and what
 * -i prints, with ocaml-light's.
 *
 * The unit's own .mli, when it has one, is checked: each val's
 * declared type an instance of the inferred one. Another unit's values
 * have their .mli's types (a unit without one: a fresh variable, not
 * checked). *)

exception Error of int * string

(* a unit's items checked; the toplevel's values and their types, as
 * -i prints them *)
val unit_ : string -> Scope.item list -> (string * string) list
