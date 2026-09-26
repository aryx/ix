(* mini-ml [-m 5|7] [-S] [-o out] [-I dir] [-i] [-unsafe-types] [-M] [-dast] [-dscope] [-dir] file.ml
 * mini-ml [-m 5|7] [-S] [-o out] -start Unit...
 * A unit into its object (mini-asm's format, for mini-ld: out, or x.5
 * or x.7 in the current directory), -m the machine (5, arm, the
 * default; 7, arm64), -S its assembly on stdout instead; another unit's
 * names from its .mli (or .ml) in the source's directory, then the
 * -Is. -start: the program's start, which initializes the units in
 * their order. -i prints the toplevel's types, as ocamlopt -i
 * its values'; -unsafe-types skips the type checker. -M prints the units a unit names (its dependencies).
 * -dast prints the parser's tree, -dscope the names
 * resolved, -dir the stack machine's code. A .mli is only parsed. An
 * error on stderr, and the exit status 1. *)

type caps = < Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr >

val main : < caps; .. > -> string array -> int
