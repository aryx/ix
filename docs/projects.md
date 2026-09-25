# The projects inside ix

ix is several projects in one repository, and they cross two ways: by
**size** (a faithful mini program or a free tiny one) and by
**machine** (real ARM, or a machine of our own). Most of ix is OCaml
that runs on the host; some of it is code that runs *inside* an
emulated machine, in assembly or C. This page says which is which.
Names in italics are planned.

## Two kinds of code

- **Host programs, in OCaml.** Every executable ix builds with dune
  (`make`, then `bin/`): the mini programs, the tiny programs, the
  emulators themselves. They run on Linux.
- **Guest code, not OCaml.** What an emulated machine runs: ARM
  executables for mini-5i and mini-qemu (from mini-cc and mini-ld, or
  from goken's compilers, or kernels like xv6 and 9pi); `.s` programs
  for tiny-arm; `.tm` assembly and C compiled by `tiny-c -tm` for
  tiny-cpu and tiny-machine. Only the last kind lives mostly in ix, in
  `tiny/tiny-os/` and the tests.

## Two sizes of host program

- **mini-xxx** (m-ix): a Plan 9 program's faithful twin, named after
  it, its output the original's byte for byte (`builder/`, `shell/`,
  `editor/`, `assembler/`, `linker/`, `compiler/`, `database/`,
  `version_control/`, `machine/`, `raspberry/`).
- **tiny-xxx** (t-ix): a free variant in one file under `tiny/`,
  named after what it does, keeping the idea and redesigning the rest.
  Two of them keep their core in a library for a second program
  (`TinyLibArm.ml`, `TinyLibCPU.ml`).

Both share `lib_core/` (files, processes, the console, logging),
`lib_security/` and `lib_compression/`.

## Two families of machine

Real ARM, whose guest code comes from real toolchains, and a machine
of our own, designed to teach, whose guest code ix writes itself:

|                      | CPU, user mode                        | machine, with devices, for a kernel |
|----------------------|---------------------------------------|-------------------------------------|
| real ARM, faithful   | mini-5i (`machine/`: arm32, arm64)    | mini-qemu (`raspberry/`: the Pi1, the Pi4 in progress; `./mini-pi`) |
| real ARM, free       | tiny-arm (`TinyArm.ml`, `TinyLibArm.ml`: arm32) | *tiny-pi* (`TinyPi.ml`: the Pi1)   |
| our own, free        | tiny-cpu (`TinyCPU.ml`, `TinyLibCPU.ml`) | tiny-machine (`TinyMachine.ml`; `./tiny-machine`) |

Each machine, with what makes its guest code and what runs on it:

| machine      | its toolchain                                     | what runs on it |
|--------------|---------------------------------------------------|-----------------|
| mini-5i      | mini-cc, mini-asm, mini-ld (goken's 5c/5l, 7c/7l the reference) | Linux and Plan 9 user programs, arm and arm64 |
| mini-qemu    | outside ix: the kernels' own builds               | xv6 (`~/xv6`), 9pi (`~/principia`), as QEMU runs them |
| tiny-arm     | its own assembler (GNU as's syntax and bytes)     | `.s` programs (`tiny/TinyArm_tests/`) |
| *tiny-pi*    | tiny-arm's assembler                              | *a page of kernel, bare-metal Pi1 programs* |
| tiny-cpu     | TinyLibCPU's assembler; `tiny-c -tm` for C        | `.tm` programs; C programs with `tiny-os/libc/` |
| tiny-machine | the same, plus csrr, csrw, eret                   | tiny-os's kernels and their programs |

tiny-assembler and tiny-c (without `-tm`) are free variants of the
real toolchain: they make arm64 Linux executables with goken's libc,
for arm64 Linux (and mini-5i), not for the tiny machines.

## The kernels

Several different projects, not versions of one (tiny-os's versions,
and how they relate to the others: [plans/plan_tiny_os.md](plans/plan_tiny_os.md)):

| kernel | what | in | runs on |
|---|---|---|---|
| tiny-os v0 (`tiny/tiny-os/v0/`) | a page of kernel: traps, a timer, round robin, protection by a window; its four programs linked with it | TinyCPU assembly | tiny-machine |
| *tiny-os v1* (`tiny/tiny-os/v1/`) | the next version, gradually toward xv6's design | C, by `tiny-c -tm` | tiny-machine |
| *TinyKernel.ml* (tiny-kernel) | the Kernel row's free variant (README's series); what it is, not decided | | |
| *mini-9pi* | 9pi's twin, the Kernel row's mini program (README) | OCaml, with a thin C/asm shim | the Pi (mini-qemu, real boards) |
| *mini-xv6* | mentioned by the author; not planned yet | | |

xv6 and 9pi themselves are not ix's: they are guest code mini-qemu is
tested with.

## What comes from outside

- **goken** (`~/goken`): principia's Plan 9 toolchain built for Linux,
  the reference for mini-asm, mini-ld, mini-cc and the tests of
  tiny-assembler and tiny-c.
- **principia** (`~/principia`): the books' C, and 9pi with its SD
  card image.
- **xv6** (`~/xv6`): its Pi ports, booted by mini-qemu.
- **xix**: the OCaml ports of the same programs, a source of ideas,
  not of code.
