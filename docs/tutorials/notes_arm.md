# An ARM emulator for user programs, from scratch: a tutorial for `machine/`

What an emulator is, and how to write one for the programs ix's
toolchain makes: the fetch-decode-execute loop, ARM's 32-bit encodings
and AArch64's, flags and conditions, addressing, the ELF process a
program starts as, and the Linux system calls it makes. It is written
for **a reader of TinyArm's code**, before the code, as the
specification of the program planned in
[`plan_arm.md`](../plans/plan_arm.md), to be checked against it.
Related systems: [`notes_arm_related_work.md`](../related-work/notes_arm_related_work.md).
The twin is 5i, principia's `machine/5i` and its book, `Machine.nw`.

Every encoding example below was decoded by binutils' objdump from a
word the corpus runs (`machine/tests/census.py`), and every system
call seen by strace on a native run, on 2026-09-24.

## 0. Where the code will be

| module (`machine/`) | what | section |
|---|---|---|
| `Bits` | fields, sign extension, carries | §3 |
| `Memory` | segments, the bus | §2 |
| `Elf`, `Linux` | the process; system calls | §2, §6 |
| `Arm32` | decode, print, execute (arm) | §3, §4 |
| `Arm64` | the same for AArch64 | §5 |
| `Cpu` | the loop, the decode cache | §1, §7 |

## 1. What an emulator does

A CPU is a loop:

```
   forever:
     w  = memory[pc]            fetch
     i  = decode w              what it is: which operation, which registers
     execute i                  change registers, memory, flags, pc
```

An emulator is that loop written as a program, the machine's state as
data: sixteen registers (or thirty-one), four flags, memory. What makes
it an emulator of *ARM* is only `decode` and `execute`; what makes it a
*user-mode* emulator is what happens at `svc`, the instruction a
program uses to call its operating system: the emulator does the call
itself, on the host.

```
   $ tinyarm hello.exe                  (planned)
   hello from libc.a: 2 + 2 = 4
```

That program, run natively under strace, makes exactly two system
calls:

```
   write(1, "hello from libc.a: 2 + 2 = 4\n", 29) = 29
   exit(0)
```

so an emulator that can run arm's integer instructions and those two
calls runs it.

## 2. The process: ELF, memory, the stack

ix's linker (`tinyld -H7`) writes ELF executables; readelf on
`hello.exe`:

```
   Machine:      ARM                          (AArch64 for arm64)
   Entry point:  0x80cc
   LOAD  offset 0x0000a0  vaddr 0x000080a0  filesz 0x06ee8  memsz 0x06ee8  R E
   LOAD  offset 0x007000  vaddr 0x0000f000  filesz 0x009c8  memsz 0x00bd0  RWE
```

Loading is copying each LOAD segment's bytes from the file to its
virtual address, the rest of `memsz` zeros (the bss), then setting the
program counter to the entry. Two more regions the program expects:
a **heap**, grown by the `brk` system call from the end of the data;
and a **stack**, near the top of the address space, where Linux puts,
from the stack pointer up: `argc`, the `argv` pointers and a zero, the
`envp` pointers and a zero, the auxiliary vector (pairs of `AT_`
numbers and values: page size, entry, random bytes...), then the
strings themselves. What goken's `_start` reads of it (argc and argv
at least) is the contract; the rest is Linux's, provided so that other
toolchains' programs start too.

Memory is segments of bytes. Every load and store goes through a small
record of functions -- the **bus** -- which here finds the segment and
checks the address (outside every segment: the program's
"segmentation fault"), and in the Raspberry Pi emulator
([`notes_pi.md`](notes_pi.md)) will go through the MMU to RAM or to a
device.

## 3. ARM (32-bit): registers, conditions, and the encoding classes

Sixteen registers, r0-r15: r13 is the stack pointer (sp), r14 the link
register (lr, where `bl` puts the return address), **r15 the program
counter** -- an ordinary register an instruction can read (and get the
instruction's address *plus 8*: a relic of the first ARM's pipeline)
or write (a jump). Four flags in the CPSR: **N** (negative), **Z**
(zero), **C** (carry), **V** (signed overflow).

Every instruction is one 32-bit word, and **every instruction is
conditional**: its top four bits name a condition on the flags (EQ: Z
set; NE; CS/CC; MI/PL; VS/VC; HI: C and not Z; LS; GE: N = V; LT; GT;
LE; AL: always), and an instruction whose condition fails does nothing.
Hence the census's `ldreq`, `movne`, `rsbmi`: 5c uses conditions
instead of short branches.

Bits 27-25 give the class:

```
   27 26 25
    0  0  0   data processing, register operand (also: multiply, halfword loads)
    0  0  1   data processing, immediate operand
    0  1  0   load/store, immediate offset
    0  1  1   load/store, register offset
    1  0  0   load/store multiple (ldm, stm: push, pop)
    1  0  1   branch (b, bl)
    1  1  0   coprocessor load/store         (FPA: plan_arm.md decision 8)
    1  1  1   coprocessor, and svc (bit 24)
```

**Data processing**, `e0823103`:

```
   1110 000 0100 0 0010 0011 00010 00 0 0011
   cond      ADD S  Rn   Rd  shift LSL   Rm       add r3, r2, r3, lsl #2
```

sixteen operations in bits 24-21 (AND EOR SUB RSB ADD ADC SBC RSC TST
TEQ CMP CMN ORR MOV BIC MVN), S (bit 20) to set the flags, and a second
operand that is either an 8-bit immediate rotated right by twice a
4-bit amount (so `#0xff000000` fits, `#0x101` does not), or a register
shifted by an immediate or by another register (LSL, LSR, ASR, ROR).
The **shifter** also produces a carry, which is C after a logical
operation with S.

**Flags after add and subtract**: N is bit 31 of the result, Z whether
it is zero, C the unsigned carry out of bit 31 (for subtraction, *not
borrow*: `cmp r0, r1` sets C when r0 ≥ r1 unsigned), V the signed
overflow: the operands had the same sign and the result has the other.
In OCaml, with 32-bit values in ints:

```ocaml
let r = (a + b) land 0xffffffff in
let c = a + b > 0xffffffff in
let v = (lnot (a lxor b)) land (a lxor r) land 0x80000000 <> 0
```

**Loads and stores**, `e59f0414` is `ldr r0, [pc, #1044]`: bits P
(pre-index), U (up), B (byte), W (write back), L (load), a base
register, a destination, and a 12-bit offset or a shifted register.
With the PC as base the address is the instruction's plus 8 plus 1044
-- how 5l loads a constant from the pool it placed after the function.
Halfwords and signed bytes (`ldrh`, `ldrsb`) have their own encoding
in class 000, an 8-bit offset split in two nibbles.

**Load and store multiple**, `e8bd8010` is `pop {r4, pc}`: an `ldm`
with sp as base, incremented after, written back, and a 16-bit mask of
registers; loading pc returns from the function.

**Branch**, `1a000003` is `bne` to 0x14 from 0: the 24-bit offset,
sign-extended, times 4, plus 8.

**Multiply** (`mul`, and `umull r0, r1, r2, r3`, a 64-bit product in
two registers, which 5c uses for `vlong`) sits in class 000 with bits
7-4 = 1001. There is no divide in arm32: 5c calls a routine in libc.

## 4. The system call, arm32

`ef000000` is `svc 0`. Linux's EABI: the call's number in **r7**, its
arguments in r0-r5, the result in r0, a failure as a negative errno
(-4095 to -1). `write` is 4, `exit` 1, `brk` 45 (Linux's
`asm/unistd-eabi.h`, checked; arm64 has its own table, the generic
one, with other numbers).
The emulator's `svc` is a function from the registers to the result:
read the arguments, do the host's call, write r0.

## 5. AArch64

Thirty-one 64-bit registers x0-x30 (x30 the link register), a stack
pointer, and the program counter apart (not a general register any
more). Register number 31 means the stack pointer in some operands and
**the zero register** (xzr, reads 0, writes vanish) in others -- the
encoding says which, and a decoder must know. The same registers read
as 32 bits are w0-w30; writing a w register zeroes the upper half.
Flags NZCV as in arm32, but only a few instructions set them and none
are conditional but branches and a few selects.

Still one word per instruction; bits 28-25 give the group:

```
   100x   data processing, immediate (add/sub, logical, move wide, bitfield)
   101x   branches, exceptions, system
   x1x0   loads and stores
   x101   data processing, register
   x111   floating point and SIMD
```

From the corpus:

```
   910043e0   add x0, sp, #0x10          (register 31 is sp here)
   f9400be0   ldr x0, [sp, #16]           12-bit offset, scaled by 8
   b9401fe1   ldr w1, [sp, #28]           scaled by 4
   a9bf7bfd   stp x29, x30, [sp, #-16]!   a pair, pre-indexed: a prologue
   1b007c20   mul w0, w1, w0              (madd with xzr)
   9ac00c20   sdiv x0, x1, x0             divide: 7c uses it, 5c cannot
   12001c00   and w0, w0, #0xff           a logical immediate
   54000060   b.eq 0xc                    19-bit offset times 4
   d4000001   svc #0                      the number in x8, arguments x0-x5
```

The one hard decoding is the **logical immediate**: `and`'s constant is
not stored but described (N, immr, imms: an element size of 2 to 64
bits, a run of ones in it, a rotation, the element repeated), so that
masks like 0xff or 0x5555... fit in 13 bits. Decoding it is a function
of a dozen lines, and the census's forms are few (`and w0, w0, #0xff`
dominates).

## 6. System calls in general

What the census found, per architecture: `write exit execve close open
rt_sigaction getpid unlink rmdir fstat setitimer clock_gettime
clock_nanosleep sigreturn read fork wait4 mkdir pipe brk kill getcwd
chdir access fchmod getdents64` (arm64 has the `*at` forms: `openat`,
`unlinkat`, `mkdirat`, `faccessat`; `clone` for fork). Most are one
host call away. Four need thought:

- **Structures.** `fstat` fills a `struct stat` whose layout is the
  guest's (arm32's `stat64` is not arm64's, nor the host's): the
  emulator builds it field by field.
- **fork** is the emulator process forking: the child is a copy with
  the same guest state, returning 0 in r0. **execve** of a guest
  program loads it into the emulator (the path names an ARM program:
  it is emulated, not handed to the host).
- **Signals.** The corpus's `alarm` test sets a timer and catches
  SIGALRM. The host's signal is noted by a handler; between two
  instructions the emulator builds Linux's signal frame on the guest
  stack (the saved registers, and a return address to a `sigreturn`),
  jumps to the guest's handler, and `sigreturn` puts the registers
  back.
- **Time** (`clock_gettime`, `nanosleep`, `setitimer`): the host's.

## 7. Making it fast enough

The naive loop decodes every instruction every time it runs. Programs
run the same instructions millions of times, so **decode once**: an
array per executable segment, indexed by the address divided by 4,
holding the decoded variant (filled on first execution). Then the loop
is: find the slot, match the variant, check the condition, do it. A
toy interpreter of this shape runs 75 million instructions a second on
this machine (`machine/tests/bench_interp.ml`), a tenth of a real
Raspberry Pi 1's speed -- enough to run ix's programs in moments.

Beyond it lie, in order of effort: **threaded code** and **closure
compilation** (decode each instruction into an OCaml closure with its
operands already chosen, and run blocks of closures: no matching left
at run time), and **dynamic binary translation** (QEMU: translate a
block of guest instructions into host machine code, cache it, run
it) -- hard in OCaml, and not needed for this corpus.

## 8. How TinyArm will be tested

- the **decoder** against objdump, on every word the corpus runs;
- **programs** run three ways -- on the CPU, under qemu, under TinyArm
  -- their output, status and system calls compared;
- **states** against qemu's register log after each instruction, the
  first divergence found automatically;
- **random instructions** of the census's forms, assembled into a
  harness and run on the CPU and in TinyArm, registers compared: the
  hardware as the oracle for every flag of every shifter form.

## 9. Exercises

- Implement Thumb (the 16-bit encoding), and run a gcc-built program.
- Closure compilation: measure it against the interpreter.
- A lazy-flags scheme like 5i's, correct for ADC and overflow: what
  must it keep?
- FPA (plan_arm.md decision 8), checked against arm64's VFP results.
- Plan 9's personality: 5i's a.out and system calls.
- A debugger: breakpoints and single-stepping over `Cpu` (the
  Debuggers book).
