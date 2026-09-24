(* What the builder and the shell do alike with children and pipes:
 * the loops around Unix's calls that an interrupt (EINTR) or a
 * reader that quit (EPIPE) would otherwise break. *)

(* all of the string to the descriptor; what a reader that quit left
 * unread is dropped *)
val write_all : Unix.file_descr -> string -> unit

(* all the descriptor gives, to its end *)
val read_all : Unix.file_descr -> string

(* the child's end *)
val waitpid : < Cap.wait; .. > -> int -> Unix.process_status

(* any child's end; None when there is no child *)
val wait_any : < Cap.wait; .. > -> (int * Unix.process_status) option

(* an environment's NAME=value entries, split at the first =; the
 * entries without one dropped *)
val split_env : string array -> (string * string) list
