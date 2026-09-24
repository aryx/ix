(* The shell: chidb's commands and SQL, a line at a time.
 *
 * A line starting with . is a command (.open .parse .opt .dbmrun
 * .headers .mode .explain .help, recognized by their name's letters at
 * the start of the word: .openx is .open); anything else is SQL, run on
 * the open database. Rows print separated by | (.mode list) or in
 * columns of 10 (.mode column); .explain on is headers and columns,
 * which is how an EXPLAIN's program reads well:
 *
 *      addr       opcode     p1         p2         p3         p4
 *      ---------- ---------- ---------- ---------- ---------- ----------
 *               0 Integer             2          0          0
 *               2 CreateTabl          4          0          0
 *
 * (CreateTable cut to 10 characters, as chidb's %-10.10s does.)
 * Messages are chidb's, on its streams: "SQL syntax error." and the
 * errors of a statement on standard output, the others on standard
 * error. *)

type caps = < Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr >

type t

val create : caps -> t

(* false, with chidb's message, if it can't be opened *)
val open_db : t -> string -> bool

(* one line of input, not empty *)
val handle : t -> string -> unit

val close : t -> unit
