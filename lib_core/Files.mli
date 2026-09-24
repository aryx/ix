(* Whole files in and out, through the capabilities to open them.
 * Shared by the assembler, linker, compiler, builder and shell. *)

(* the whole file (a pipe too); Sys_error if it cannot be read *)
val read : < Cap.open_in; .. > -> Fpath.t -> string

(* None if it cannot be opened *)
val read_opt : < Cap.open_in; .. > -> Fpath.t -> string option

(* created (with [perm], 0o644 by default) or truncated *)
val write : < Cap.open_out; .. > -> ?perm:int -> Fpath.t -> string -> unit

(* a path from the command line; Error for "" (Fpath's only refusal
 * besides a NUL) *)
val path : string -> (Fpath.t, string) result
