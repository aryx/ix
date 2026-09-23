(* The one parser, for both machines: Plan 9's assembly syntax to
 * Asm's items. The syntax is the same for arm and arm64; what differs
 * is the register names (Asm.register), so this parser never asks
 * which machine it reads for, but to name a register.
 *
 * Labels and n(PC) become Target, an index into the items: the pc that
 * 5a and 7a count (every item but GLOBL and DATA) is turned into the
 * item it names, in a second pass, once all the labels are known.
 *
 *     parse Arm "x.s" "loop: SUB $1, R0\n BNE loop\n"
 *       = items [ Ins SUB [$1; R0]; Ins BNE [Target 0] ]
 *
 * No preprocessor: a # line is an error (goken's libc .s files have
 * none; principia's kernel .s files wait for the compiler's). *)

exception Error of int * string   (* a line, a message *)

val parse : Asm.arch -> string -> string -> Asm.obj
