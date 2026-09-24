(* tinycc [-m 5|7] [-S] [-x] [-o out] [-Idir] [-Dname[=value]] file.c
 * -m the machine (5, arm, the default; 7, arm64), -S the listing on
 * stdout, -x the trees parsed, without code; the object in TinyAsm's
 * format, for TinyLd, to out or x.5 (x.7) in the current directory,
 * as 5c. 5c's other flags are ignored. *)

type caps =
    < open_in : string -> Cap.FS_.open_in;
      open_out : string -> Cap.FS_.open_out; stderr : Cap.Console_.stderr;
      stdout : Cap.Console_.stdout >

val main :
  < open_in : string -> Cap.FS_.open_in;
    open_out : string -> Cap.FS_.open_out; stderr : Cap.Console_.stderr;
    stdout : Cap.Console_.stdout; .. > ->
  string array -> int
