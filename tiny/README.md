# tiny/

The free variants of ix's programs, one file each: what is left of a
program when compatibility is dropped and only its idea is kept,
written after its faithful twin and from what that one taught. The
files, children and pipes they share with the twins come from
`lib_core/` (`Files`, `Procs`), not copied into each.

| file | its twin | the idea kept |
|---|---|---|
| `TinyBuildSystem.ml` | `builder/` (TinyMk, mk) | rules, `%`, stamps as digests, one pass with `-j` |
| `TinyShell.ml` | `shell/` (TinyRc, rc) | lists as the only value, words joined by adjacency, redirections around the command |
| `TinyEditor.ml` | `editor/` (TinyEd, ed) | sam's command language: dot a range, loops over matches, changes in parallel |
| `TinyAssembler.ml` | `assembler/`, `linker/` (TinyAsm, TinyLd; 5a/5l, 7a/7l) | no separate compilation: all of a program's assembly into an arm64 executable, sizes known before addresses, a word per closure |
| `TinyC.ml` | `compiler/` (TinyCompiler; 5c, 7c) | a C subset through a stack machine of its own, the stack in registers, 7c's calling convention so it links with goken's libc |

Each has its tests beside it, `TinyXxx_test.sh`, run by `make test`
(TinyAssembler's and TinyC's, which need goken, by `make test-goken`;
TinyC's programs are `TinyC_tests/`, and `TinyC_fuzz.py` writes random
ones);
the plans' Status logs (`docs/plans/`) tell how each was chosen and
checked.
