(* Plan 9's ARGBEGIN: single-letter flags, grouped (-cp) or apart, a
 * flag's argument attached (-ffile) or next (-f file), "--" or the
 * first word not starting with '-' ending them. *)

exception Usage

(* the flags seen, in order, with their arguments ("" for none), and
 * the rest; [with_arg] lists the letters that take one *)
val parse : flags:string -> with_arg:string -> string list -> (char * string) list * string list

val has : (char * string) list -> char -> bool
val get : (char * string) list -> char -> string option
val all : (char * string) list -> char -> string list
