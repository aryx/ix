(* Variables, functions, and the environment that carries both to
 * children.
 *
 * A variable is a list of strings; unset and () are the same. A local
 * assignment, x=v cmd, and a for loop's variable are dynamic: set for
 * the command, and put back after, whatever it did (principia's
 * Xlocal, Xunlocal), so a function called inside sees them.
 *
 * {b The environment.} Every variable is exported, a list joined by
 * \001 so that a child rc splits it back; an empty list is not
 * exported (on Plan 9 it is an empty /env file, which reads back as
 * (); a Unix program given X= sees one empty string -- the bug TinyMk
 * met building xix). Functions are exported too, as fn#name={body}
 * and a newline (checked on 9base's rc: fn#g={echo g} and a newline,
 * which it needs to read one back), and read back when rc starts.
 * $path is a list kept in step with $PATH, joined by :.
 *
 * References: principia's var.c, env.c; plan9port's rc (unix.c); Tom
 * Duff, "Rc -- The Plan 9 Shell" (1990), "Environment": on Plan 9 each
 * variable is a file in /env, its "components terminated by zero
 * bytes", and a function is /env/fn#name -- the zero byte a Unix
 * environment string cannot hold, hence \001 here, as plan9port. *)

type t

val create : unit -> t

val get : t -> string -> string list
val set : t -> string -> string list -> unit

(* [local t name value f]: [f] with [name] set to [value], then put back *)
val local : t -> string -> string list -> (unit -> 'a) -> 'a

val status : t -> string
val set_status : t -> string -> unit

(* is $status true: every character a 0 or a | (status.c)? *)
val ok : t -> bool

val fn : t -> string -> Ast.cmd option
val set_fn : t -> string -> Ast.cmd option -> unit
val vars : t -> (string * string list) list   (* sorted, for whatis *)

(* the flags rc was given, and those set by the flag builtin *)
val flag : t -> char -> bool
val set_flag : t -> char -> bool -> unit

(* the environment, in (a program's name=value strings) and out *)
val import : t -> string array -> unit
val export : t -> string array
