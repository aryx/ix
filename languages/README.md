# languages/: ix's compilers, one directory per language

Each compiler writes mini-asm's objects (`assembler/Asm.mli`), which
mini-ld (`linker/`) encodes and links: Plan 9's split, where the
compiler never knows an address. The assembler and the linker stay
outside: they are the machine's end of the toolchain, shared by every
language, not a language of their own.

| folder | language | program | plan |
|---|---|---|---|
| `c/` | Plan 9's C, as 5c and 7c at `-O0`, byte for byte | mini-cc | [plan_cc.md](../docs/plans/plan_cc.md) |
| `ml/` | ocaml-light's ML, native; its target: mini-9pi | mini-ml (planned) | [plan_ml.md](../docs/plans/plan_ml.md) |

The one-file variants are in `tiny/` (TinyC.ml, and TinyML.ml,
planned), beside the others.
