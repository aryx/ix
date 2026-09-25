(* ELF executables, 32 and 64 bits, little-endian: what a loader needs
 * (the machine, the entry, the loadable segments).
 *
 *   hello.exe (arm32, mini-ld -H7):  entry 0x80cc
 *     LOAD 0x0000a0 -> 0x80a0 filesz 0x6ee8 memsz 0x6ee8  R E
 *     LOAD 0x007000 -> 0xf000 filesz 0x09c8 memsz 0x0bd0  RWE
 *
 * References: the System V ABI's ELF chapter and ARM's ELF supplement
 * (from memory); readelf, run, for the example. *)

type machine = Arm | Aarch64 | Other of int

type segment = { offset : int; vaddr : int; filesz : int; memsz : int; exec : bool }

type t = { machine : machine; entry : int; segments : segment list }

exception Bad of string

val parse : string -> t
