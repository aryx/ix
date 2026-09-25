# Plan: mini-5i, an ARM emulator for user programs, arm32 and arm64 (`machine/`)

Companions: [`notes_arm.md`](../tutorials/notes_arm.md), the tutorial
(fetch, decode, execute; ARM's and AArch64's encodings, flags and
addressing; the ELF process and Linux's system calls; making an
interpreter fast), and
[`notes_arm_related_work.md`](../related-work/notes_arm_related_work.md)
(from IBM's 360 emulation and SimH to Shade, QEMU, Rosetta and
TinyEMU; interpreters, threaded code and binary translation). The
next plan, [`plan_pi.md`](plan_pi.md), extends the CPU cores built
here into a Raspberry Pi (Pi1, then a 64-bit Pi).

The twin is 5i, Plan 9's ARM emulator, the subject of principia's
Machine book (`machine/5i`, `Machine.nw`, 9,445 lines): about 3,200
lines of C (the book's count) with a db-like debugger, a profiler and
Plan 9's system calls. goken builds it on Linux (`machines/5i`, with
`syscall_posix.c`). There is no xix twin (`xix/machine` is empty).

The eighth ix program. The author chose it ("maybe we can first do a
tiny ARM emulator, main the CPU and emulating linux syscalls, a la 5i
and qemu-user-arm ... and later on do another tiny but for the
Raspberry Pi"; "ideally we can emulate the arm32 and arm64"; "we don't
have to emulate all the instructions; enough to emulate the binaries
produced by ix toolchain (and maybe also the goken and xix
toolchain)"; "we also want to be fast enough to be usable").

## Context

An emulator runs a program written for one machine on another:
it holds the emulated machine's registers and memory as data, and for
each instruction does what the hardware would do -- fetch the word at
the program counter, decode it, execute it. A user-mode emulator (5i,
qemu-arm) runs one program, and where the program asks its operating
system for something (a system call), the emulator asks the host's.

Why now, and why this way:

- **ix's toolchain makes ARM programs; nothing of ix runs them yet.**
  mini-cc, mini-asm and mini-ld produce arm and arm64 Linux executables,
  byte for byte goken's; so far Linux runs them. An emulator closes the
  loop, and is the base of the kernel and debugger books.
- **The oracle is the hardware itself.** This machine's CPU (a
  Neoverse-N1) runs AArch32 at user level and the kernel has
  `CONFIG_COMPAT`: goken's arm32 `hello.exe` prints its line natively,
  as it does under `qemu-arm` (checked, 2026-09-24). So a program can
  be run three ways -- on the CPU, under qemu-user, under mini-5i --
  its output, exit status and system calls (`strace`) compared; and
  qemu logs the registers after each instruction, which finds the
  first one that diverges.
- **The instruction set is what the corpus runs, measured.**
  `machine/tests/census.py` runs goken's 17 `hello_libc` programs, as
  linked by goken and by ix (34 executables, and ix's `t/` twins),
  under qemu with `-d in_asm`, and disassembles every word executed:
  **arm32, 89 mnemonics** (the condition suffixes counted apart: `ldr`,
  `ldreq`, ...), 752 operand forms, **2,311 distinct words**; **arm64,
  45 mnemonics**, 2,218 words (`census_arm.txt`, `census_arm64.txt`).
  Integer only: no floating point runs in the corpus.
- **A plain interpreter is fast enough, measured.** A toy interpreter
  in the style planned (a variant per decoded instruction, one match,
  a condition, a shifter, loads and stores, flags) runs **75 million
  instructions a second** as written, untuned
  (`machine/tests/bench_interp.ml`). A real one does more per
  instruction; 30 MIPS is the target (decision 7).

## Principles

Those of [`../README.md`](../README.md), and three of its own:

- **Three references, each for what it knows.** The CPU for behaviour
  (a program's output, exit status and system calls: `strace` on the
  native run); qemu-user for state (the registers after each
  instruction, `-d cpu -one-insn-per-tb`); binutils' objdump for the
  decoder (every word of the census decoded by mini-5i's disassembler
  and by objdump, the same instruction). 5i is the twin for structure
  and the book, not for behaviour (it has no V flag, no ADC/SBC, and
  Plan 9's system calls).
- **The corpus decides the instruction set.** What ix's, goken's and
  xix's toolchains emit and the corpus runs is implemented (for the
  Pi, what 9pi's and xv6's gcc-built kernels run too: plan_pi.md's
  census adds a Thumb-2 subset, VFP and system instructions); any other
  word stops the emulator with "unimplemented instruction WORD at PC"
  and the program's name. Principle 1's "every feature kept" becomes
  "every instruction the toolchains emit": gcc's Thumb-2 and NEON are
  left out of user mode (no ix program contains them); the Pi brings
  back only the few its kernels run.
- **Hardware as fuzzing oracle.** Beyond the corpus, random instruction
  sequences of the forms the census found (data processing with every
  shifter form and flag, loads and stores with every addressing mode)
  are assembled by mini-asm into a harness, run natively and under
  mini-5i, and the registers and flags compared.

## The interface

```
mini-5i [-t] [-s] program.exe [args...]      arm32 or arm64, by the ELF header
  -t   trace: each instruction, disassembled, and the registers it wrote
  -s   statistics: instructions run, by kind; MIPS
mini-5i -d program.exe                       the disassembly (checked against objdump)
```

The program's standard input, output and error are mini-5i's; its
exit status is mini-5i's. A debugger (5i's `:b`, `:s`, `$r`) is the
Debuggers book's; the `-t` trace is what the tests need now.

## Target layout

```
machine/                     library ix_machine; the mini-5i executable
  Bits.ml(i)                 fields, sign extension, rotations, 32/64-bit
                             arithmetic with carry and overflow
  Memory.ml(i)               the address space: segments of Bytes, a
                             bus record (load/store by size), checked
  Elf.ml(i)                  ELF32 and ELF64 executables: the loadable
                             segments, the entry
  Arm32.ml(i)                decode: word -> instr (a variant); print
                             (the disassembler); execute
  Arm64.ml(i)                the same for AArch64
  Linux.ml(i)                the process: initial stack, auxv; the
                             system calls, by number per architecture
  Cpu.ml(i)                  the loop, the decode cache, statistics,
                             the trace
  CLI.ml(i), Main.ml
machine/tests/               census.py, bench_interp.ml; the
                             differential scripts; Testo for decoders
tiny/TinyArm.ml              the free variant (see "Outside 5i")
```

**The size target**: Bits 80, Memory 150, Elf 100, Arm32 900 (decode
300, print 200, execute 400), Arm64 1,000, Linux 500, Cpu 150,
CLI+Main 100: **about 3,000 lines**, near 5i's 3,200 of C for two
architectures instead of one (5i's debugger and profiler not counted:
they are other books').

## Groundwork decisions

### 1. An instruction is a variant, decoded once from its word

5i decodes into an index into a table of handler functions
(`arm_class` then `itab[]`), and each handler re-extracts its fields
from the word. mini-5i decodes a word once into a value that says what
it is:

```ocaml
type instr =
  | Dp of { cond : cond; op : dp_op; s : bool; rd : reg; rn : reg; op2 : operand }
  | Mul of { cond; long : mul_kind; ... }
  | Mem of { cond; load : bool; size : size; signed : bool; rd; rn;
             offset : offset; index : Pre | Post; writeback : bool }
  | Block of { cond; load : bool; rn : reg; regs : int; mode : Ia | Ib | Da | Db; writeback : bool }
  | Branch of { cond; link : bool; offset : int }
  | Svc of { cond; imm : int }
and operand = Imm of int * int (* value, carry out *) | Shift of reg * shift * amount
```

A misread field is then a type error, not a wrong register, and the
disassembler is a printer of the variant -- which checks the decoder
against objdump on every word the corpus runs.

### 2. Flags are four fields, computed, not lazy

5i keeps the last comparison's operands and recomputes a condition
from them (a lazy scheme with no V flag and a partial carry); it is
enough for 5c's code and wrong for ADC, SBC and overflow conditions,
and the Pi's kernel reads and writes the CPSR. mini-5i's state has N,
Z, C, V as they are, computed by each flag-setting instruction, so the
state is the architecture's and comparable with qemu's after every
instruction.

### 3. Registers: arm32 in ints, arm64 in Int64 unboxed where it counts

A 32-bit register fits an OCaml int (63 bits), masked. A 64-bit one
does not: arm64's registers are `Int64.t`, which OCaml unboxes in
local arithmetic but boxes in arrays; so arm64's register file is
stored in a `Bytes` of 32 × 8 (read and written with `get_int64_le`,
unboxed), a choice measured in phase 5 against a plain `Int64.t
array`. (Measured: the array won, 24.0 MIPS against 17.9; see Status.)

One more constraint, from the web (plan_pi.md, decision 9): compiled
by js_of_ocaml, OCaml's `int` has 32 bits, not 63, and `Int64` is
emulated. So the arithmetic that depends on the width -- masking to 32
bits, carries and overflows, 64-bit values -- is in `Bits` and nowhere
else, written to give the same results under both (a carry computed by
unsigned comparison, never as `a + b > 0xffffffff`), and tested under
both; the cores use no C stubs, and `Unix` only at the edges (`Linux`,
the CLI).

mini-qemu constrains this from the start (plan_pi.md, decision
2): xv6's arm-pi3 enters AArch64 and drops to AArch32 on the same core,
whose 32-bit registers are the low halves of x0-x14. So the two cores
share one register file (the 64-bit one), the AArch32 core reading and
writing the low halves; the phase 5 measurement decides its
representation for both.

### 4. Memory: segments of Bytes behind a bus

The loader maps the ELF's segments, a heap (`brk`) and a stack; an
access outside them stops the program ("segmentation fault at ADDR",
signal 11's exit status, as the kernel's would). Every load and store
goes through a record of functions (`load8/16/32/64`, `store...`), the
bus: user mode's does a segment lookup (the last one cached), the Pi's
will translate through the MMU and reach devices. Unaligned accesses
are those ARMv6+ and AArch64 allow (loads and stores of words
unaligned work); 5i's ARMv5 rotation is not kept.

### 5. The decode cache: by address, filled on first execution

`Cpu` keeps, per executable segment, an array of decoded instructions
(or `None`), filled when an address first runs. A store into an
executable segment clears its slot (self-modifying code is not in the
corpus, but a JIT test is cheap). This is 5i's unimplemented
`icache.c`, and the whole of "decode once".

### 6. Linux's system calls, the corpus's, mapped to the host's

The census found 27 system calls per architecture (strace, native):
`write exit execve close open(at) rt_sigaction getpid unlink(at) rmdir
fstat(64) setitimer clock_gettime(64) clock_nanosleep sigreturn read
fork/clone wait4 mkdir(at) pipe(2) brk kill getcwd chdir access
fchmod getdents64`. Each is a function from the registers (arm32: the
number in r7, arguments in r0-r5; arm64: x8, x0-x5; `svc #0`) to a
result in r0/x0, a negative errno on failure, through the host's
calls (and the capabilities). What needs care:

- **structures** (`stat`, `timespec`, `itimerval`, `dirent64`) laid
  out as the guest's ABI has them, not the host's;
- **fork** is the emulator forking, the child continuing the emulated
  program; **execve** loads the new program into the same emulator
  (the path is a guest program: it is emulated, not run on the host);
- **signals** (the corpus's `alarm` test: `setitimer`, SIGALRM, a
  handler): the host signal is noted and delivered between
  instructions, a signal frame built on the guest's stack as Linux
  builds it, `sigreturn` restoring it;
- an unknown number: "unimplemented system call N (name)", stop.

### 7. An interpreter first; faster only when measured

Principle 8's simple version: fetch through the decode cache, one
`match` on the instruction, the condition first. The target is 30
MIPS on the corpus and on a CPU-bound benchmark (mini-cc compiling
itself would do), measured against qemu-arm (translation to host code)
and goken's 5i (an interpreter). Only if the target is missed: flags
as ints, unchecked access within a segment, specialized closures per
instruction (decode into a closure, "closure compilation": the road
between interpretation and QEMU's translation, kept for the tutorial's
exercises otherwise).

### 8. arm32 floating point: FPA, later, checked against arm64

5c's floating point is assembled by 5l, and by mini-ld, as **FPA**
instructions (the old ARM floating-point coprocessor), which Plan 9's
kernel emulates in software; no Linux, qemu-arm or Raspberry Pi runs
them (plan_asm.md: "encoded, not run"). The corpus runs none. If a
program needs them (phase 7), mini-5i emulates FPA with host doubles,
checked by running the same C compiled for arm64 natively (VFP there:
the same IEEE doubles, the same output).

## Deliberate differences from 5i

1. Linux's executables and system calls, not Plan 9's (5i's a.out and
   Plan 9 system calls may come back as a second personality, phase
   8, to run 5i's own tests).
2. N, Z, C, V as the architecture has them (decision 2); ADC, SBC,
   RSC, and the VS/VC conditions, which 5i lacks.
3. ARMv6+ unaligned accesses, not 5i's rotation.
4. No debugger or profiler: a trace (`-t`) and counts (`-s`).

## Phases

1. **Arm32 decode and print.** Checked: every word of the census
   (2,311) printed as objdump prints it (modulo spelling: a table of
   the few differences, e.g. `push` for `stmdb sp!`).
2. **Memory, Elf, the loop, Arm32's execution, write and exit.**
   `hello.exe` runs. Checked: its output and exit status, native and
   mini-5i.
3. **Linux's system calls for the corpus.** All 34 arm32 programs (and
   ix's `t/` builds): output, exit status and the sequence of system
   calls (mini-5i's `-t` log of them against strace) identical.
4. **The random harness**: random instruction blocks against the
   CPU. (Planned also: the registers after each instruction against
   qemu-arm's `-d cpu` log; dropped, see Status.)
5. **Arm64**: decode and print (objdump on the 2,218 words), execute,
   the same Linux module with arm64's numbers and structures; all 34
   programs.
6. **Speed**: MIPS measured on the corpus and a long benchmark,
   against qemu and 5i; tuning only if under 30.
7. **FPA** (if a program needs it), against arm64 native.
8. **Optional: 5i's personality**, Plan 9's a.out and system calls,
   against goken's 5i on its Plan 9 test binaries.
9. **The free variants**, two (the author: "maybe can do a TinyArm.ml
   9a and a TinyCPU 9b"; "both"): **9a, `tiny/TinyArm.ml`**, an
   arm32 subset interpreter and a matching assembler in one file;
   **9b, `tiny/TinyCPU.ml`**, a toy load-store machine of our own
   design, as a teaching machine (MIX's and MMIX's road).

## Outside 5i: TinyArm.ml

Free, in one file. Candidates, to choose when written: an arm32 subset
(the census's commonest forms) interpreter and a matching assembler in
one file, so that a program is written, assembled and run in it; or an
emulator of a toy load-store machine of our own design, 16 registers,
fixed 32-bit encoding, as a teaching machine (MIX's and MMIX's road).
Checked by its laws: an assembled program runs to its expected
result; the same program on mini-5i (machine/) gives the same output.

## Verification

`make test` runs the decoder check on the census, the corpus
differential (native, qemu, mini-5i), and a short random harness;
`make test-goken` rebuilds the corpus from goken.

## Status

2026-09-24: plan written; the census and the speed estimate measured.

**Phase 1 done** (2026-09-24): `Bits` and `Arm32` (the variant, the
decoder, objdump's printing). Checked (`machine/tests/decode_check.py`):
all 2,311 words of the corpus, and 120,000 random words of the classes
decoded, printed as objdump 2.42 prints them; about one random word in
ten is left `Undefined` (miscellaneous-space forms, `movw`/`movt`, the
signed multiplies: not in the corpus); the same printing compiled by
js_of_ocaml is identical to the native one.

What the random words found that the corpus did not: r10's name (sl);
the unprivileged transfers (`ldrt`, `strbt`, `strht`) a post-indexed
W bit means; multiply's bits 27-22; objdump's own spellings (`#imm8,
rot` for a non-canonical rotation, `stmia`, `ldmfd`/`stmfd` for one
register from sp, ldrd's single register, a halfword's `#0`, no `!` on
a pc-based halfword). And js_of_ocaml found the first width bug, an
unsigned test written as `<= 0xff`: hence `Bits.ule32`.

**Phases 2 and 3 done for arm32** (2026-09-24): `Memory`, `Elf`,
`Arm32`'s execution, `Cpu`'s loop with its decode cache, `Linux` (the
process, 30 system calls, signals, fork, exec) behind a host record,
`Host` on Unix, `mini-5i [-t] [-s] [-y]`. All 34 programs of the arm32
corpus (goken's and ix's links of the 17 hello_libc tests) run with
the same standard output, exit status and **system-call sequence**
(`strace` on the native run, mini-5i's `-y`) as on this machine's CPU
(`machine/tests/corpus.py`).

What the runs found: the kernel maps an ELF's segments by whole pages,
and a program may use the rest of its last page past its bss (goken's
`mem.exe` does, its `brk` having failed: goken's `brk` takes any answer
at or above the request as success, and Linux's randomized heap answers
far above) -- found by reading the native process's `/proc/PID/maps`
under a delayed `exit`; `openat` relative to a directory descriptor
(`dirread`); goken's arm signal handlers have no restorer, so a handler
returns through the kernel's sigpage: mini-5i maps a trampoline
(`mov r7, #119; svc 0`) and builds its own frame.
**Phase 4 done** (2026-09-24), in a different shape than planned:
`machine/tests/random_blocks.py` writes random blocks of arm32
instructions, each into its own static ELF (a prologue loading random
registers and flags, the block, an epilogue writing all registers, the
flags and a 512-byte buffer to stdout). It runs each ELF on the CPU
and under mini-5i, and on a difference bisects to the first differing
instruction. It covers every data processing form (immediate, rotated
immediate, shift by immediate and by register, RRX), all conditions,
the multiplies, `clz`, `mrs`/`msr`, and word, byte, halfword, signed
and doubleword transfers, unaligned where ARMv7 allows. It covers
pre- and post-indexing, writeback, and `ldm`/`stm` in all four modes.
The generator never writes r12 (every transfer's base), sp or pc, and
a transfer writing back r12 is unconditional, so every address it
generates is known to fall inside the buffer. 6,000 blocks of 30
instructions: no difference (`make test` runs 3,000, in about 3 s).
The harness catches deliberate bugs: a wrong RRX carry was caught by 1
block in 300, a wrong SBC carry-in by 49 in 300, both bisected to the
right instruction.

The qemu-arm per-instruction log was not built: the CPU itself is the
stronger oracle, and qemu places the stack, auxv and heap elsewhere,
so its registers differ from mini-5i's at the first stack address.
`qemu-arm -d cpu -one-insn-per-tb` remains the tool to trace a
divergence the corpus finds.

What it found: nothing wrong in the execution; for the decoder, `mrs`
and `msr` (added, the harness needing them to set and read the flags).
And the CPSR's other bits belong to the machine: this ARMv8 core's
AArch32 `mrs` returns the flags plus SSBS (bit 23), with the mode bits
0. mini-5i returns the flags plus `usr` (0x10), as an ARMv6 or ARMv7
does; the harness compares the flags only.

**Phase 5 done** (2026-09-24): `Arm64`, decode, print and execute;
`Linux.syscall64` (asm-generic's numbers: the `*at` calls, `clone` as
fork, a 128-byte `struct stat`, 64-bit timespecs and vectors, its own
signal frame and trampoline); `Cpu.run64`; `mini-5i` runs either.
Checked:

- the decoder (`decode_check.py -64`): the 2,218 words of the corpus,
  and 330,000 random words of the decoded classes (data processing,
  branches, loads and stores; SIMD excluded, objdump 2.42 itself
  crashing on some of those), printed as objdump prints them, aliases
  included (`mov`, `cmp`, `lsl`, `ubfx`, `sxtw`, `cset`, `mul`...);
  js_of_ocaml's printing identical;
- all 34 arm64 programs (`corpus.py 7`): standard output, exit status,
  system-call sequence;
- random blocks (`random_blocks.py -64`): every data processing form,
  `msr`/`mrs nzcv` (added for it), loads and stores of every size and
  addressing mode, pairs, conditional branches over one instruction;
  6,000 blocks of 30, no difference. Deliberate `cls` and `csneg` bugs
  are caught (40 and 23 blocks of 300).

What they found: `csneg` decoded as `csinv`, the move to sp's `mov`
alias (`movz` cannot write sp, so objdump keeps `mov` whatever the
value), `adrp`'s offset too large for js_of_ocaml's ints (kept in
pages), and `adr` to a negative address, which wraps in 64 bits
(mini-5i zero-extended it). And the corpus harness now runs the native
programs under `setarch -R`: goken's `brk` takes any answer at or
above its request as success, and Linux's randomized heap made arm64
`mem.exe` use memory it never got (a native segfault; mini-5i, whose
layout is fixed, ran it).

Decision 3, measured (`machine/tests/bench64.py`, a 7-instruction
loop, 140 million instructions): registers in an `Int64.t array`, 24.0
MIPS; in a `Bytes` read with `get_int64_le`, 17.9; with the
`%caml_bytes_get64u` primitive, 20.8. A `Bytes` read boxes a new
`Int64` at each call not inlined, where the array's values are already
boxed. The array it is. (The shared register file for the Pi3's two
modes, plan_pi.md, will take the same measurement.) 24 MIPS is under
the 30 target: phase 6.

**Phase 6 done** (2026-09-24): over 30 MIPS on both, measured by
`machine/tests/bench.py 5|7` (a loop of 7 instructions, 140 million
run; mini-5i's checksum equal to the CPU's), in dune's release profile:

| | arm32 | arm64 |
|---|---|---|
| mini-5i, before phase 6 (dev profile) | 18.5 | 20.9 |
| the same code, release profile | 24.8 | 29.2 |
| mini-5i now, release profile | **36.0** | **34.5** |
| mini-5i now, dev profile | 22.8 | 27.1 |
| goken's 5i (`bench_plan9_arm.s`, its default build) | 6 | -- |
| qemu-user (translation to host code) | 1,100 | 1,035 |
| the CPU (Neoverse-N1) | ~5,000 | ~3,600 |

Found with valgrind's callgrind (no perf on this machine):

- **dune's dev profile compiles libraries with `-opaque`**, which stops
  inlining across modules: `Bits.mask32`, `ult32` and the rest become
  calls. Release (what `opam install` and `dune build --release`
  build) inlines them; the speed is quoted for it.
- **allocation on the hot path**: `Memory`'s lookup returned a pair
  and an option on every access (now: the last segment's fields cached
  in the memory record, the offset returned); arm32's shifter returned
  a pair (value, carry out), `Bits.add_carry` a triple, a data
  processing result an option and `set` a closure (now: the carry out
  in a module-level `bool ref`, `add32`/`carry32`/`overflow32`,
  `mul32` in ints: exact under js_of_ocaml too, whose multiplication
  wraps at 32 bits).
- arm64's register writes go through `caml_modify` (a boxed `Int64`
  stored in an array); a Bigarray of `int64` avoids the barrier but
  measured the same (34.7-35.3 against 34.6): kept the array.

Not done, as not needed: flags computed lazily, a decode into
closures, translation to OCaml bytecode or host code (decision 7's
roads, the tutorial's exercises).

**Phase 8 done** (2026-09-24): `Plan9`, 5i's personality: the arm
a.out (`-H2`) loaded as 5i's `initmemory`/`initstk` lay it out, the
system calls of principia's `sys.h` the libc makes (arguments on the
stack from sp+4, errors as strings, `errstr` exchanging them), and the
files Plan 9's libc reaches the system through, the emulator's own:
`#c/pid`, `/dev/bintime`, `/env/NAME` (the environment kept across
exec, as Plan 9 keeps it outside the program), `/proc/PID/note`.
Directories read as 9P stat records; notes are delivered as
principia's kernel does (a Ureg and the note on the stack, the
`notify` handler called, `noted(NCONT)` putting the Ureg back, a note
no one handles killing); a child's exit string reaches its parent's
`await` through a pipe `rfork` makes. `mini-5i` tells an a.out from an
ELF by its magic.

The corpus: goken's 17 `hello_libc` programs, built with `GOOS=plan9`
(`linker/tests/libc.sh`, now `H=-H2`: goken's 5l and ix's mini-ld write
all 17 byte for byte the same). Checked by `machine/tests/plan9.py`:
each run under mini-5i, under 5i, and as the same C program's Linux
build on the CPU (the tests print the same lines everywhere). **17 of
17 as expected**:

- 13 print what the Linux build prints;
- `fork` and `notify` as Plan 9 means, not Linux: `exit(42)` is
  `exits("error")` (Plan 9 has no exit codes), so wait's message is
  "fork.exe PID: error", not "42"; a note no handler accepts kills the
  process (`noted(NDFLT)`), where Linux's postnote of an unknown note
  just fails;
- `atexit` as 5i: goken's Plan 9 `exits` is the raw system call, so no
  atexit handler runs (real Plan 9's `exits` runs them, then
  `_exits`): a goken libc bug;
- `dirread` by its own checks: **its Linux build fails natively**, arm32
  and arm64, creating directories with garbage names (`mkdir("\7")`,
  strace) -- a goken bug that `corpus.py` counted as agreement, mini-5i
  reproducing the native failure faithfully.

5i agrees with mini-5i on 10 of the 17; the other 7 need system calls
5i lacks (`alarm`, `rfork`, `fstat`) or files it does not provide
(`#c/pid`, `/env`, `/proc/PID/note`).

**Phase 9a done** (2026-09-24): `tiny/TinyArm.ml` (`tiny-arm`, 760
lines), a computer in one file: an assembler for an arm32 subset in
GNU as's syntax (data processing with every operand form and the
shift aliases, conditions and `s` everywhere, mul and mla, word and
byte transfers in every addressing mode, the block transfers and
push/pop, the branches, svc, adr, `ldr =` and its literal pool), an
interpreter that decodes the words it runs (read, write and exit, as
Linux numbers them), and an ELF writer. One variant is read by the
parser, the encoder, the decoder, the printer and the executor.
Checked by `tiny/TinyArm_test.sh` against the real tools:

- five programs (`TinyArm_tests/`: hello, fib, a sieve, a reversal of
  standard input, a checksum over the other forms) assemble to GNU as's
  text section byte for byte; their listing, each word decoded back,
  is objdump's text; each runs the same here, on the CPU (the ELF
  written) and under machine/'s `mini-5i`, output and status;
- random lines of the subset's syntax (3,000 in `make test`; 120,000
  over several seeds tried): GNU as's bytes, objdump's text.

What GNU as taught: the smallest rotation for an immediate; the
complementary instruction when a value does not fit (mov and mvn, add
and sub, cmp and cmn, and and bic, adc and sbc); `ldr =` as a mov or
mvn when the value fits one, the pool deduplicated, after everything;
a single-register push or pop as a str or ldr, but for `push {sp}`
(whose store would write back the register it stores), kept a block.

**Phase 9b done** (2026-09-25): `tiny/TinyCPU.ml` (`tiny-cpu`,
400 lines), a machine of our own for teaching (MIX's and MMIX's road):
16 registers of 32 bits, r0 zero, 2^20 bytes of memory taken modulo
its size, no flags (a branch compares two registers; slt), one 32-bit
format (an 8-bit opcode, two registers, a 16-bit immediate naming the
third), every case defined (division by zero and its overflow as
RISC-V answers them); an assembler with li, la, call, ret (the machine
is new, so nothing else writes its words: MIX came with MIXAL); and an
interpreter, which is the definition.

Checked by `tiny/TinyCPU_test.sh`: seven programs
(`TinyCPU_tests/`: hello, fib, recursive factorials, a sieve, an
insertion sort, upper-casing standard input, calls through a table)
print their `.expected` (computed by Python); 200 random programs in
`make test`, straight lines of every instruction with branches and jal
over one: their listing, reassembled, lists the same words (a lui
printed with a bit lost fails all of them).

A static translator to arm32 (a Linux ELF, the guest's registers in
memory, jalr through a table of every word's translation) was written
with it, 185 lines, then removed (2026-09-25): binary translation is a
second topic, and a free variant teaches one. It had caught, by random
programs interpreted and translated, a translated sar made logical and
a division by zero made 0; git history has it.
Renamed TinyMachine.ml to TinyCPU.ml then (`tiny-cpu`): a CPU and its
memory, no devices. The name TinyMachine.ml goes to the planned CPU
with devices (plan_pi.md).
