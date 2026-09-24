# Plan: TinyArm, an ARM emulator for user programs, arm32 and arm64 (`machine/`)

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
  tinycc, tinyasm and tinyld produce arm and arm64 Linux executables,
  byte for byte goken's; so far Linux runs them. An emulator closes the
  loop, and is the base of the kernel and debugger books.
- **The oracle is the hardware itself.** This machine's CPU (a
  Neoverse-N1) runs AArch32 at user level and the kernel has
  `CONFIG_COMPAT`: goken's arm32 `hello.exe` prints its line natively,
  as it does under `qemu-arm` (checked, 2026-09-24). So a program can
  be run three ways -- on the CPU, under qemu-user, under TinyArm --
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
  decoder (every word of the census decoded by TinyArm's disassembler
  and by objdump, the same instruction). 5i is the twin for structure
  and the book, not for behaviour (it has no V flag, no ADC/SBC, and
  Plan 9's system calls).
- **The corpus decides the instruction set.** What ix's, goken's and
  xix's toolchains emit and the corpus runs is implemented; any other
  word stops the emulator with "unimplemented instruction WORD at PC"
  and the program's name. Principle 1's "every feature kept" becomes
  "every instruction the toolchains emit": gcc's Thumb-2 and NEON,
  which no ix program contains, are left out on purpose.
- **Hardware as fuzzing oracle.** Beyond the corpus, random instruction
  sequences of the forms the census found (data processing with every
  shifter form and flag, loads and stores with every addressing mode)
  are assembled by tinyasm into a harness, run natively and under
  TinyArm, and the registers and flags compared.

## The interface

```
tinyarm [-t] [-s] program.exe [args...]      arm32 or arm64, by the ELF header
  -t   trace: each instruction, disassembled, and the registers it wrote
  -s   statistics: instructions run, by kind; MIPS
tinyarm -d program.exe                       the disassembly (checked against objdump)
```

The program's standard input, output and error are TinyArm's; its
exit status is TinyArm's. A debugger (5i's `:b`, `:s`, `$r`) is the
Debuggers book's; the `-t` trace is what the tests need now.

## Target layout

```
machine/                     library ix_machine; the tinyarm executable
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
from the word. TinyArm decodes a word once into a value that says what
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
and the Pi's kernel reads and writes the CPSR. TinyArm's state has N,
Z, C, V as they are, computed by each flag-setting instruction, so the
state is the architecture's and comparable with qemu's after every
instruction.

### 3. Registers: arm32 in ints, arm64 in Int64 unboxed where it counts

A 32-bit register fits an OCaml int (63 bits), masked. A 64-bit one
does not: arm64's registers are `Int64.t`, which OCaml unboxes in
local arithmetic but boxes in arrays; so arm64's register file is
stored in a `Bytes` of 32 × 8 (read and written with `get_int64_le`,
unboxed), a choice measured in phase 5 against a plain `Int64.t
array`.

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
MIPS on the corpus and on a CPU-bound benchmark (tinycc compiling
itself would do), measured against qemu-arm (translation to host code)
and goken's 5i (an interpreter). Only if the target is missed: flags
as ints, unchecked access within a segment, specialized closures per
instruction (decode into a closure, "closure compilation": the road
between interpretation and QEMU's translation, kept for the tutorial's
exercises otherwise).

### 8. arm32 floating point: FPA, later, checked against arm64

5c's floating point is assembled by 5l, and by tinyld, as **FPA**
instructions (the old ARM floating-point coprocessor), which Plan 9's
kernel emulates in software; no Linux, qemu-arm or Raspberry Pi runs
them (plan_asm.md: "encoded, not run"). The corpus runs none. If a
program needs them (phase 7), TinyArm emulates FPA with host doubles,
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
   TinyArm.
3. **Linux's system calls for the corpus.** All 34 arm32 programs (and
   ix's `t/` builds): output, exit status and the sequence of system
   calls (TinyArm's `-t` log of them against strace) identical.
4. **The per-instruction differential and the random harness.** The
   registers after each instruction against qemu-arm's `-d cpu` log,
   the first divergence reported; random instruction blocks against
   the CPU.
5. **Arm64**: decode and print (objdump on the 2,218 words), execute,
   the same Linux module with arm64's numbers and structures; all 34
   programs.
6. **Speed**: MIPS measured on the corpus and a long benchmark,
   against qemu and 5i; tuning only if under 30.
7. **FPA** (if a program needs it), against arm64 native.
8. **Optional: 5i's personality**, Plan 9's a.out and system calls,
   against goken's 5i on its Plan 9 test binaries.
9. **`tiny/TinyArm.ml`.**

## Outside 5i: TinyArm.ml

Free, in one file. Candidates, to choose when written: an arm32 subset
(the census's commonest forms) interpreter and a matching assembler in
one file, so that a program is written, assembled and run in it; or an
emulator of a toy load-store machine of our own design, 16 registers,
fixed 32-bit encoding, as a teaching machine (MIX's and MMIX's road).
Checked by its laws: an assembled program runs to its expected
result; the same program on TinyArm (machine/) gives the same output.

## Verification

`make test` runs the decoder check on the census, the corpus
differential (native, qemu, TinyArm), and a short random harness;
`make test-goken` rebuilds the corpus from goken.

## Status

2026-09-24: plan written; the census and the speed estimate measured.
