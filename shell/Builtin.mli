(* The builtins: the commands the shell runs itself, because they
 * change the shell (principia's builtins.c).
 *
 *     cd [dir]         chdir; no dir: $home; a relative dir is tried in
 *                      each of $cdpath. Failing: "Can't cd dir: why",
 *                      status can't cd (checked on 9base's rc)
 *     exit [status]    end rc, with this status or $status
 *     . [-i] file args read file's commands, $* set to args; file is
 *                      searched in $path; -i: interactive (a prompt,
 *                      errors don't end it)
 *     eval args        the args joined by spaces, as commands
 *     exec cmd         replace rc with cmd (and exec alone keeps the
 *                      redirections it is given, for rc itself)
 *     shift [n]        drop n words from $*
 *     wait [pid]       for the children started with &
 *     whatis names     how rc would read each back: x=(a b c), fn f
 *                      {...}, builtin cd, /usr/bin/ls, or "x: not found"
 *     flag c [+-]      is -c set (status "" or "flag not set"), set it,
 *                      clear it
 *     rfork, finit     accepted, and nothing on a Unix host (9base: rfork
 *                      e succeeds with an empty status)
 *
 * Why cd must be a builtin, the Principia book's question: chdir
 * changes the directory of the process that calls it, and a cd program
 * would change only its own, and then exit. *)

(* register them in Eval.builtins *)
val init : unit -> unit
