(* Configuration lookups, "remote.origin.url" style, as git9's conf.c
 * does them: line by line, no real parser.
 *
 *   [remote "origin"]
 *   	url = git://example.org/repo
 *
 * [lookup caps files "remote \"origin\".url"] splits at the first dot,
 * scans for a line starting with "[remote \"origin\"]" (at column 0: an indented
 * header is not seen), then for a line whose text starts with the key
 * and then, after blanks, "="; the value is the rest, trimmed. A
 * section of several words must be quoted as git writes it. *)

(* the values, the first file with one winning; [all] for every match
 * in that file *)
val lookup : < Cap.open_in; .. > -> ?all:bool -> Fpath.t list -> string -> string list

(* the files git9 reads: the repository's, $HOME/lib/git/config,
 * /lib/git/config *)
val default_files : Fpath.t -> Fpath.t list
