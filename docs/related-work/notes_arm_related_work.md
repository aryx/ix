# Related work: emulators, from the IBM 360 to QEMU and Rosetta

Where mini-5i ([`plan_arm.md`](../plans/plan_arm.md),
[`notes_arm.md`](../tutorials/notes_arm.md)) sits among the real
systems. principia's `machine/lineage.txt` (349 lines; checked) lists
the family; what is not from it or from code read here is **from
memory**, marked, to check before it is quoted in a `.mli`.

## The lineage (from principia's lineage.txt, checked)

IBM 360 emulation (1964: running the 1401's programs on the 360); the
teaching machines, MIX, MMIX, SPIM; the architecture simulators,
SimpleScalar, gem5; the instrumentation and translation tools, Shade,
Pin, HP Dynamo, DynamoRIO, Valgrind; the full-system simulators SimOS,
Disco, Simics; Plan 9's 5i (1993) and its siblings ki, vi, qi; the
hobbyists' SimH, Bochs, MAME, DOSBox; Wine; QEMU (0.9 to 5.0),
TinyEMU and JSLinux; the commercial translators FX!32, Transmeta,
Rosetta and Rosetta 2; the hypervisors, VMware to Firecracker; box64.

## Three ways to run another machine's code

- **Interpretation** (5i, SimH, Bochs, SPIM): fetch, decode, execute,
  one instruction at a time. Simple, portable, exact, slow -- a factor
  of 10 to 100 below native (from memory). mini-5i starts here.
- **Threaded code and pre-decoding**: J. R. Bell, "Threaded Code"
  (CACM, 1973; from memory), for Forth-like interpreters; applied to
  emulators, instructions are decoded once into a form that dispatches
  fast. Feeley and Lapalme's "Using Closures for Code Generation"
  (Computer Languages, 1987; from memory) is the functional version:
  compile to closures, the road plan_arm.md keeps for later.
- **Dynamic binary translation**: Shade (Cmelik and Keppel,
  SIGMETRICS 1994; from memory), Embra in SimOS (Witchel and
  Rosenblum, 1996; from memory), Dynamo (Bala, Duesterwald and
  Banerjia, PLDI 2000; from memory); **QEMU** (F. Bellard, "QEMU, a Fast
  and Portable Dynamic Translator", USENIX ATC 2005; from memory):
  guest blocks translated to host code through a small intermediate
  language (TCG), chained, cached. qemu-user is QEMU with Linux's
  system calls emulated instead of a machine: exactly mini-5i's
  interface, and its reference. Rosetta 2 (Apple, 2020; from memory)
  translates ahead of time where it can.

## Emulators worth reading

- **5i** (Plan 9, 1993; principia's Machine book, checked): about
  3,200 lines, an interpreter with a table of handlers, lazy flags
  (no V: enough for 5c's code), Plan 9 system calls, a db-like
  debugger and a profiler. mini-5i's twin in structure.
- **TinyEMU** (F. Bellard, 2017-2019; from memory): a RISC-V and x86
  system emulator of a few thousand lines of C, virtio devices, the
  engine of JSLinux in the browser. The model of a small, complete,
  readable full-system emulator -- for plan_pi.md.
- **Unicorn** (from memory, 2015): QEMU's CPU cores cut out as a
  library, without devices or system calls -- the split plan_arm.md and
  plan_pi.md make, by design.
- **box64 and FEX** (from memory): user-mode translators of x86-64 to
  arm64, the modern qemu-user.

## Specifications of the architecture

- The **ARM Architecture Reference Manual** (ARM DDI 0406 for ARMv7-A
  and R, DDI 0487 for ARMv8-A; from memory): the encodings, and
  pseudocode for every instruction.
- **ARM's machine-readable specification** (A. Reid, "Trustworthy
  Specifications of ARM v8-A and v8-M System Level Architecture",
  FMCAD 2016; from memory): the pseudocode made executable, then
  translated to Sail (Armstrong et al., "ISA Semantics for ARMv8-A,
  RISC-V, and CHERI-MIPS", POPL 2019; from memory) -- an emulator
  derived from the specification, the opposite end from a hand-written
  one; a useful oracle for corner cases the corpus does not reach.

## Where mini-5i sits

An interpreter, like 5i, for two architectures, running what ix's
toolchains make, in OCaml with instructions as variants; tested not
against another emulator but against the CPU it emulates, which this
machine happens to be. The Raspberry Pi emulator (plan_pi.md) reuses
its cores; the related work of full-system emulation is in
[`notes_pi_related_work.md`](notes_pi_related_work.md).
