(* polymorphic equality and compare on structures *)
type t = A | B of int | C of t * t
let () =
  print_string (if [ 1; 2; 3 ] = [ 1; 2; 3 ] then "eq" else "ne"); print_newline ();
  print_string (if (1, "a") = (1, "b") then "eq" else "ne"); print_newline ();
  print_int (compare [ 1; 2 ] [ 1; 3 ]); print_int (compare [ 1; 2 ] [ 1 ]); print_int (compare (2, 1) (1, 2)); print_newline ();
  print_int (compare A (B 1)); print_int (compare (B 1) (B 0)); print_int (compare (C (A, B 2)) (C (A, B 2))); print_newline ();
  print_string (if Some [ "x" ] = Some [ "x" ] then "eq" else "ne"); print_newline ();
  (* claude: not [ 1 ] == [ 1 ], unspecified: ocamlopt shares the constants *)
  let l = [ 3; 1; 2 ] in print_string (if l == l then "same" else "different"); print_newline ();
  print_string (if (1, 2) < (1, 3) && [] < [ 0 ] && "" < "a" then "ok" else "ko"); print_newline ()
