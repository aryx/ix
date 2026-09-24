(* Linux.host on the real Linux under TinyArm: its calls through Unix
 * (and the capabilities), Linux's flags, errnos, signal numbers and
 * wait statuses translated to and from OCaml's. A guest's file
 * descriptors are TinyArm's own (qemu-user's choice): what the guest
 * opens, TinyArm has open. *)

type caps = < Cap.fork; Cap.wait; Cap.chdir; Cap.kill; Cap.open_in; Cap.open_out >

val create : caps -> Linux.host
