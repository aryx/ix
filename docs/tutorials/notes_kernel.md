# An xv6 in OCaml, from scratch: a tutorial for `kernel/`

What it takes to write an operating system kernel in a garbage-collected
language, on a real machine, the Raspberry Pi 1: the language's runtime
brought up without an operating system under it, the machine's traps
reaching OCaml code, processes whose kernel stacks the collector must
know, memory and page tables handled as data. Written for **a reader
of mini-xv6's code**, step by step as the code is (`kernel/step1/`,
`step2/`, `step3/`, ...), following [`plan_kernel.md`](../plans/plan_kernel.md).
It builds on [`notes_pi.md`](notes_pi.md) (the Pi1, ARM's privileged
state, its MMU) and on xv6 itself. Related systems:
[`notes_kernel_related_work.md`](../related-work/notes_kernel_related_work.md).

## 1. The kernel, and why OCaml

xv6 (MIT's teaching Unix, the V6 design in modern C) is a kernel of a
few thousand lines: processes that fork, exec, wait and exit; a
scheduler switching between them on a timer; sleep and wakeup; a file
system (a buffer cache, a log, inodes, directories, paths); file
descriptors, pipes, a console; about twenty system calls. Its ARM
ports for the Pi1 (`~/xv6/forks/arm-pi1`) boot under QEMU and
mini-qemu and pass its `usertests`.

Most of xv6 is not about the machine. It is data structures and the
error paths around them: a process table, states and transitions,
reference counts, lists of free blocks, "return -1 and undo what was
done" repeated in every system call. That is where OCaml is better
than C: a process's state as a variant carrying its data (`Sleeping of
chan`, `Zombie of status`) instead of an integer and fields valid in
some states only; a file as `Pipe of pipe | Inode of inode | Device of
int` instead of a tag and three pointers; an exception to unwind a
failed call instead of the `goto bad` chains. The rest -- a quarter,
perhaps -- is the machine: page table entries, the trap frame, the
context switch, device registers. There OCaml needs help (section 6).

What OCaml costs is its runtime: the kernel stands on a memory manager
of its own, the garbage collector, which a C kernel does not have. The
steps below are about making that true on bare metal.

## 2. What the runtime is

An OCaml program compiled to native code (ocamlopt; here ocaml-light's
arm backend, `kernel/ocaml-light.sh`) is machine code plus a runtime
in C, 13,000 lines in ocaml-light (`asmrun/` and `byterun/`):

- **Two heaps.** New values go in the minor heap, a bump pointer over
  a fixed area (256KB here); when it fills, the live values are
  copied to the major heap, managed by an incremental mark-and-sweep
  with a free list, and compaction. A collection must find every
  value the program can still reach: the **roots**.
- **The roots**: the global variables of the OCaml modules, the
  registers saved when the collector was called, and the **stack**.
  The compiler records, for every place code calls out (a function
  call, an allocation that may collect), which stack slots hold
  values: the *frame descriptors*. The collector walks the stack from
  its top (`caml_bottom_of_stack`, set when OCaml calls C) using the
  return addresses to find each frame's descriptor.
- **Calls into C** (`external`) go through `caml_c_call`, which records
  where the OCaml stack stops (the bottom and the last return address)
  so that a collection triggered from C can still walk it.
- **Callbacks from C** (`callback`, `Callback.register`) start a new
  stretch of OCaml frames below the C ones, and push a link to the
  saved state of the stretch above: the collector follows the chain.

What the runtime asks of the system underneath is small: `malloc` for
its heaps, `memmove` and friends, `write` for its error messages,
`sprintf` for `string_of_int`, a few maths functions, a division
routine (the Pi1's ARMv6 has no divide instruction). Files, signals,
`getenv` are only for programs that ask. The Plan 9 port of ocaml-light
(`config/plan9.h`) and ~/xix/kernel's `fakes.c` did the same shimming.

## 3. Step 1: OCaml bare-metal (`kernel/step1/`)

The chain from the reset to OCaml:

```
  the firmware (or QEMU's loader)       kernel.img at 0x8000, SVC mode, IRQs off
    -> start.s: _start                   a stack, the VFP on, the bss cleared
      -> libc.c: kmain                   argv = {"mini-xv6"}
        -> caml_main (asmrun/startup.c)  the heaps (malloc), the globals
          -> caml_start_program (arm.S)  OCaml's world: its registers set up
            -> Main's top level           print, allocate, collect, raise
```

- **The image**: Main.ml compiled with `-output-obj` (the program and
  the parts of the stdlib it uses in one object), the runtime's C
  compiled `-ffreestanding` for ARMv6KZ with the VFP, `libc.c`,
  `start.s`, linked at 0x8000 (`kernel.ld`) and made a raw image, the
  way the Pi1's firmware loads `kernel.img`.
- **libc.c**: the PL011 for stdout and stderr; `malloc` a bump pointer
  from the end of the image (the runtime frees little: its heap only
  grows); `sprintf` for the integers; the rest a panic naming itself.
- **What went wrong on the way** is the useful part, each a lesson in
  what "no operating system" means:
  - *The Thumb trap.* The first link used GCC's libgcc for the
    divisions; Ubuntu's armhf libgcc is Thumb-2 code for ARMv7, which
    the ARM1176 cannot run. The first division (`blx __udivsi3`, in the
    GC's slice computation) switched to Thumb and took an undefined
    instruction; the vector at 0 held zeros (no handler yet), which
    ARM decodes as a harmless `andeq`, so the CPU slid through memory
    back to `_start` at 0x8000 and started the runtime again, and
    again, until `malloc` ran out: "not enough memory for the initial
    heap". A crash that looks like a reboot loop, and an error message
    about something else. libc.c has its own divisions now.
  - *The stack with no floor.* `List.init 100000` is not tail
    recursive in ocaml-light: 100,000 frames on a 64KB stack. Nothing
    stops a stack pointer on bare metal: it ran down through the bss
    (the runtime's own globals) and below address 0 before anything
    faulted. An MMU and a guard page are what a kernel gives its
    stacks; this one has neither yet.
  - *The collector computes with doubles* (how much to mark per
    slice): the kernel needs the VFP on (`start.s`), and mini-qemu's
    CPU needed the VFP's arithmetic (added then, checked against the
    real CPU).

## 4. Step 2: a trap (`kernel/step2/`)

A system call on ARM (notes_pi.md, section 3): the user program runs
`swi`; the CPU switches to SVC mode (its own r13 and r14 swapped in),
saves the user's CPSR in SPSR_svc and the next instruction's address in
r14_svc, and jumps to the vector at 0x08. Back is `movs pc, lr`: the
pc from r14, the CPSR from SPSR, user mode again.

mini-xv6's path through it:

```
  user.s        push the arguments, r0 = SYS_write, swi #0x40
  start.s       svc_entry: the user's r0-r12, sp, lr, pc, CPSR -> trapframe
  machine.c     trap(): callback( *caml_named_value("trap") )
  Main.ml       trap (): read r0 (the call), the arguments from the
                user's stack (xv6's argint), do it, result -> trapframe.r0
  start.s       user_return: the registers from trapframe, movs pc, lr
```

The kernel's side of memory is a **typed view**: the trap frame is 17
words at an address, and `Trapframe.r n`, `Trapframe.sp ()` read them
through three externals (`Mem.get8`, `get32`, `set32`). OCaml sees
numbers and named fields; C and assembly do the loads and stores.

**Where the trap runs, and why the collector is fine.** Entering user
mode the first time is an OCaml call, `user_enter pc sp`, to C, which
never returns: it jumps to `user_return`. At that moment the SVC
stack holds Main's frames and the C call's, and `caml_c_call` has
recorded where OCaml's part stops. A trap enters with r13_svc where it
was left, below those frames:

```
  high   | Main's top level (OCaml)          <- the stretch the GC knows
         | caml_c_call -> user_enter (C)        (bottom and last return
         |                                       address saved by caml_c_call)
         | svc_entry -> trap() (C)
         | callback: a link to the state above
  low    | trap, syscall (OCaml)             <- a new stretch
```

The callback's link chains the two stretches, so a collection inside
the handler walks both. Step 2 runs a full major collection at every
system call to prove it. This works because there is one program: its
kernel stack is the one stack.

## 5. Step 3: processes, and whose stack the collector walks (`kernel/step3/`)

xv6 gives every process a kernel stack. A process that blocks inside a
system call -- `read` on an empty pipe, `wait` for a child -- calls
`sleep`, which saves its registers and switches to the scheduler on
another stack; its kernel stack keeps the frames of the call in
progress until `wakeup`. So at any moment there are several stacks
holding live kernel frames, and in an OCaml kernel those frames hold
OCaml values.

ocaml-light's collector walks one stack: the current one, through its
chain of callback links, starting from a few globals. A switch does two
things, and neither needs a change to the runtime:

1. **The runtime's view of the stack travels with the registers.**
   `caml_bottom_of_stack`, `caml_last_return_address`, `caml_gc_regs`,
   `caml_exception_pointer` and `local_roots` describe *the running*
   stack; `k_swtch` saves them into the process's context and puts its
   own back when it resumes. `k_swtch` is an OCaml `external`, so the
   switch happens right where `caml_c_call` has just recorded the
   process's last OCaml frame: the saved view is exact.
2. **The collector is shown the other stacks.** `roots.c` calls a hook,
   `scan_roots_hook`, after the current stack, and exports
   `do_local_roots`, which walks any stack given its view: the
   mechanism OCaml's systhreads uses for its threads. `scan_stacks`
   walks every context but the running one.

A new process has an empty kernel stack: it starts in a C trampoline,
its view empty, and enters OCaml by `callback`, whose link records
"nothing above". The check: around every switch, a sleeping process
holds young values that only its stack refers to, while the scheduler
allocates and forces a minor and a major collection (which move young
values, and free what nobody refers to); when it resumes, it checks
them. With the hook they are intact; without it, the first resume finds
them gone and the next round takes a data abort.

The alternatives, for comparison: one kernel stack and every blocking
call written as a continuation (the collector sees one stack; the
kernel's code turns inside out); OCaml 5's effects and fibers (the
runtime does the stack switching; a much larger runtime than
ocaml-light's).

## 5b. Steps 4 and 5: the MMU and the timer (`kernel/step4/`, `step5/`)

**The layout is xv6 arm-pi1's**, and it is what makes OCaml's ints
enough: a user's addresses from 0 to 1GB (TTBR0, a 4KB table per
process: TTBCR's N = 2), the kernel at KERNBASE, 0x80000000 (TTBR1,
1MB sections), the devices at 0xFE000000, the vectors at 0xFFFF0000
(address 0 is the user's). The kernel is linked at KERNBASE + 0x8000
and loaded at 0x8000: its boot runs at the physical addresses, fills
the kernel's table, turns the MMU on and jumps to the linked ones.
OCaml never holds a kernel address: it reaches physical memory by
physical address (below 512MB), and C adds KERNBASE.

```
  0           the user's program (a copy, its own pages)
  (a page)    the guard: not mapped
  then        the user's stack
  < 1GB       the user's end (1GB itself is not a 31-bit int)
  0x80000000  the kernel: its code, the OCaml heap, the processes' pages
  0xFE000000  the devices
  0xFFFF0000  the vectors
```

Two bugs on the way are worth knowing. `0x40000000`, written as the
user's bound, is not an OCaml int on the Pi1 (the largest is
0x3fffffff): it wrapped to `min_int`, and every address looked out of
bounds. And the boot first pointed TTBR0 at the empty user table, then
set N = 2: in between, the kernel's own addresses went through the
empty table. QEMU let it pass, its TLB still holding them; mini-qemu,
which empties its TLB on every TTBR write, faulted: the stricter
emulator found the kernel's bug.

**Page table entries are records**: `L1_fault | Coarse of int` for
the first level, `L2_fault | Page of page` with `{ pa; perm; xn }` for
the second, `encode` and `decode` the only places that know the bits.
`walk`, `map`, `copyin` (a system call's buffer read only where the
user could) and freeing a space are short functions over them.

**The timer** (step 5) interrupts user mode only: the kernel runs with
IRQs masked, so no interrupt lands in the kernel or in the collector.
When nothing can run, the scheduler waits with `wfi` (a pending
interrupt ends it, masked or not) and handles the tick itself. A tick
wakes sleepers and preempts the running process; a spinning process
that never makes a system call no longer keeps the CPU.

## 6. Memory as data: a small language of views

The kernel handles memory the OCaml heap does not own: user pages, page
tables, the trap frame, the disk's blocks, device registers. The plan's
answer is not a new language but an embedded one: typed views over raw
memory.

- **Words and bytes**: a few externals (`get8`, `get32`, `set32`...).
- **Addresses fit an int** because mini-xv6 keeps every address below
  1GB: OCaml's ints are 31 bits on the Pi1, and the Pi1's RAM (0-512MB)
  and its devices (0x20000000) are all below 0x40000000. A full 32-bit
  word (a CPSR, a device register with bit 31) goes through `Int32`.
- **Layouts**: a record type and its offsets for each structure, the
  trap frame first, then the on-disk inode, the superblock, a
  directory entry; the fields read and written by name.
- **Page table entries as records**: ARMv6's short descriptors
  (notes_pi.md, section 4) decoded into `{ pa; ap; domain; ... }` and
  encoded back, the bit twiddling in one place.

## 7. Step 4: xv6's structure, and a mini twin

With processes switching, the rest is xv6 itself, in OCaml: fork,
exec (reading an ELF), wait and exit, sleep and wakeup, the file
system over xv6's own `fs.img` format, pipes, the console. The test is
ix's usual one: xv6 arm-pi1's own user programs -- the shell, `ls`,
`usertests` -- compiled for the C kernel, run unchanged on mini-xv6
under mini-qemu, their output compared with the C kernel's. That makes
mini-xv6 a *mini* twin: its behaviour xv6's, its code OCaml's.

## 8. How it is tested

`kernel/test.sh` builds each step and runs its `kernel.img` under
mini-qemu and QEMU's `raspi1ap` (loaded at 0x8000, as the firmware
does), the console compared with the step's `expected`. It is part of
`make test-pi`; ocaml-light's cross compiler is built once, in /tmp,
from a clone of ~/ocaml-light (`kernel/ocaml-light.sh`).

## 9. Exercises

- A guard page under each kernel stack (step 1's overflow, caught).
- The console's input: the PL011's receive interrupt, a line
  discipline, `read` on fd 0.
- A system call that allocates a lot, and a measurement of the
  collector's pauses inside traps.
- Step 3 the other way: one kernel stack and blocking calls as
  continuations; compare the two kernels' code.
- The same kernel on the Pi4 (arm64: 63-bit ints, no 1GB rule).
