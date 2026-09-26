(* an uncaught exception with arguments: its message, exit 2, and
 * stdout's buffer lost (ocaml-light doesn't flush it) *)
exception Error of int * string
let () = print_string "lost"; print_newline (); print_string "this too"; raise (Error (42, "message"))
