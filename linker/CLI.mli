(* tinyld -m 5|7 [-H2|-H6|-H7] [-E entry] [-o out] files...
 * tinyld -m 5|7 -a lib.a objects...  (a library) *)
type caps = < Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr >

val main : < caps; .. > -> string array -> int
