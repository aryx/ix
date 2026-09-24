(* The programs' traces, by the Logs library, on stderr: none but the
 * warnings by default, more with IX_LOG=info or IX_LOG=debug (an
 * environment variable, as the programs' flags are their originals').
 * What the programs print as their originals do is not logging and
 * does not go through here. *)
(* [name]: the program's, heading each line *)
val setup : < Cap.env; Cap.stderr; .. > -> name:string -> unit
