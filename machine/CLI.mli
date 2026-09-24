(* tinyarm [-t] [-s] program [args...]: the program run, its output
 * and exit status TinyArm's. -t traces each instruction to standard
 * error (address, disassembly); -s prints the count and the speed. *)

val main : < Cap.argv; Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr; Cap.fork; Cap.wait; Cap.chdir; Cap.kill; Cap.exec; Cap.env; .. > -> int
