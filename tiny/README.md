# tiny/

The tiny programs of ix (t-ix): the free variants of its mini
programs (m-ix), one file each (but TinyArm and TinyCPU, whose CPUs
are libraries, `TinyLibArm.ml` and `TinyLibCPU.ml`, for TinyPi.ml,
planned, and TinyMachine.ml), installed as
tiny-build, tiny-shell, ... (the second column): what is left of a
program when compatibility is dropped and only its idea is kept,
written after its faithful twin and from what that one taught. The
files, children and pipes they share with the twins come from
`lib_core/` (`Files`, `Procs`), not copied into each.

| file | executable | its twin | the idea kept |
|---|---|---|---|
| `TinyBuildSystem.ml` | tiny-build | `builder/` (mini-mk, mk) | rules, `%`, stamps as digests, one pass with `-j` |
| `TinyShell.ml` | tiny-shell | `shell/` (mini-rc, rc) | lists as the only value, words joined by adjacency, redirections around the command |
| `TinyEditor.ml` | tiny-editor | `editor/` (mini-ed, ed) | sam's command language: dot a range, loops over matches, changes in parallel |
| `TinyAssembler.ml` | tiny-assembler | `assembler/`, `linker/` (mini-asm, mini-ld; 5a/5l, 7a/7l) | no separate compilation: all of a program's assembly into an arm64 executable, sizes known before addresses, a word per closure |
| `TinyC.ml` | tiny-c | `compiler/` (mini-cc; 5c, 7c) | a C subset through a stack machine of its own, the stack in registers, 7c's calling convention so it links with goken's libc; and with `-tm` a second back end, for TinyCPU, with its runtime (`tiny-os/start.tm`, and a libc in C, `tiny-os/libc.c`), the two printing the same |
| `TinyDatabase.ml` | tiny-db | `database/` (mini-chidb; chidb) | the relational algebra as the query language, a pipeline (`t \| where ... \| group ... \| sort ...`); a copy-on-write B-tree, so every statement is atomic by one header write |
| `TinyArm.ml`, `TinyLibArm.ml` | tiny-arm | `machine/` (mini-5i; 5i) | a computer in one file: an arm32 subset assembled (GNU as's syntax and bytes), run word by word by an interpreter, written as an ELF the CPU runs too; one instruction variant read by the parser, the encoder, the decoder, the printer and the executor |
| `TinyCPU.ml`, `TinyLibCPU.ml` | tiny-cpu | `machine/` (mini-5i; 5i), with Knuth's MIX and MMIX | a machine of our own design, for teaching: 16 registers, r0 zero, no flags, one instruction format, every case defined; an assembler (a new machine has no other: nothing else writes its words) and an interpreter (the definition); the listing reassembles to the same words; the CPU a library, TinyMachine.ml's |
| `TinyMachine.ml` | tiny-machine | `raspberry/` (mini-qemu), with Project Oberon and RISC-V's privileged specification | TinyCPU's CPU with what a kernel needs, designed: two modes, one trap (epc, cause, tval, tvec) and eret, a timer counting instructions, protection by a window (base, bound), a console and a halt at the top of memory; a raw image (`-o`, linking several `.tm`) loaded at 0; a page of kernel, `tiny-os/kernel.tm`, running four programs (`tiny-os/a.tm` to `d.tm`), killing the two that misbehave |
| `TinyVCS.ml` | tiny-vcs | `version_control/` (mini-git; git9) | git's objects, trees and DAG; the repository as one hash (an operation log, so every command is atomic and undoable); no staging area; merges that always succeed, conflicts committed as data |

`tiny-os/` is what runs on the machines, built by the tiny tools as a
program is built by its toolchain: TinyKernel v0 (`kernel.tm`) and
its four programs, linked by tiny-machine; tiny-c -tm's runtime
(`start.tm`, `libc.c`, `libc.h`); `hello.c`, for tiny-cpu. Its
Makefile takes the tools from the PATH (after `dune install`) or from
ix's `bin/`: `make -C tiny/tiny-os run`, `make -C tiny/tiny-os
run-hello`.

Each has its tests beside it, `TinyXxx_test.sh`, run by `make test`
(TinyAssembler's and TinyC's, which need goken, by `make test-goken`;
TinyC's programs are `TinyC_tests/`, and `TinyC_fuzz.py` writes random
ones);
the plans' Status logs (`docs/plans/`) tell how each was chosen and
checked.
