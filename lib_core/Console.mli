(* Standard output and error, through their capabilities *)

(* unbuffered by us: stdout's own buffer *)
val print : < Cap.stdout; .. > -> string -> unit

(* flushed, so that it comes out in order with a child's *)
val eprint : < Cap.stderr; .. > -> string -> unit
