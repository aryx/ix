(* Processes and file descriptors: what a shell asks of the kernel.
 *
 *     $ ls -l | wc -l
 *     pipe()            -> fds r, w
 *     fork() -> child:   dup2(w, 1); close r, w; execve("/bin/ls", ...)
 *     in rc:             dup2(r, 0); run wc -l (forking it), put fd 0 back
 *     wait for the child; $status = "ls's|wc's"
 *
 * A program is looked up in $path (a name with a / is used as is), and
 * exec'd with the environment of Env.export. If it can't be, the child
 * says why on standard error ("x: No such file or directory", as
 * 9base's rc) and exits 1.
 *
 * {b Status.} A child's end is a string: "" for success, the exit
 * code otherwise, and for a signal plan9port's name for it, which rc
 * also prints with the pid (checked on 9base's rc):
 *
 *     exit 3       3              kill -9      signal: sys: kill
 *     exit 300     44             kill -15     signal: kill
 *     SIGPIPE      signal: sys: write on closed pipe
 *
 * {b Redirections are done in the shell}, around the command, and
 * undone after: the fds a command changes are first copied away and
 * then put back. So a builtin or a function sees them as a program
 * does (rc only applies them before an exec).
 *
 * References: D. M. Ritchie and K. Thompson, "The UNIX Time-Sharing
 * System" (CACM, 1974): process creation as two calls, fork and exec,
 * and the shell as an ordinary program; between the two, the child
 * sets up its own file descriptors, which is how the diagram above
 * works. Dennis Ritchie, "The Evolution of the Unix Time-sharing
 * System" (AT&T Bell Laboratories Technical Journal, 1984), for how
 * pipes came into Unix, at Doug McIlroy's urging. *)

type caps = < Cap.fork; Cap.exec; Cap.wait; Cap.open_in; Cap.open_out >

type fd = int

(* [search ~path name]: the file to exec *)
val search : path:string list -> string -> string option

(* exec a program, never returning *)
val exec : < Cap.exec; .. > -> path:string list -> env:string array -> string list -> 'a

(* [fork caps f]: f runs in a child, which exits with the code f
 * returns; the parent gets the child's pid *)
val fork : < Cap.fork; .. > -> (unit -> int) -> int

(* wait for this child; its status *)
val wait : < Cap.wait; .. > -> int -> string

(* wait for any child: its pid and status, None if there is none *)
val wait_any : < Cap.wait; .. > -> (int * string) option

(* a status as an exit code: a true one ("" "0|0") 0, else its leading
 * number, as rc's atoi ("3|4" 3), or 1 if that is 0 or none ("0|4") *)
val code : string -> int

val pipe : unit -> fd * fd   (* read end, write end *)
val dup2 : fd -> fd -> unit
val close : fd -> unit

(* [with_fds fds f]: run f, then put back the fds it changed *)
val with_fds : fd list -> (unit -> 'a) -> 'a

(* open a redirection's file *)
val open_file : < Cap.open_in; Cap.open_out; .. > -> Ast.rkind -> string -> fd

(* write a whole string to an fd *)
val write : fd -> string -> unit

(* everything a child writes to [f]'s standard output *)
val read_all : fd -> string
