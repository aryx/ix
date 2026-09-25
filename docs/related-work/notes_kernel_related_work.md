# Related work: kernels in garbage-collected languages, and xv6's descendants

Where mini-xv6 ([`plan_kernel.md`](../plans/plan_kernel.md),
[`notes_kernel.md`](../tutorials/notes_kernel.md)) sits. The machine
side is in [`notes_pi_related_work.md`](notes_pi_related_work.md).
Names and dates not read here are **from memory**, marked, to check
before they are quoted in a `.mli`.

## Systems written in a language with a collector

- **Lisp machines** (MIT's CADR, Symbolics' Genera, 1970s-80s; from
  memory): the whole system, device drivers included, in Lisp, with a
  garbage collector the hardware helped (tagged memory). The first
  answer to "can a kernel be garbage collected": yes, if the machine
  is built for it.
- **Smalltalk-80** (Xerox PARC, 1980; from memory): the system and the
  language one, a virtual machine under both; the model of a system
  whose every object is live and inspectable.
- **Oberon** (Wirth and Gutknecht, ETH, 1987-; *Project Oberon*,
  revised 2013; from memory): an operating system, compiler and
  graphical interface in a type-safe language with a collector, on a
  workstation of its own design, explained in one book. The closest
  in spirit to ix: a whole system small enough to read, a language
  with a collector, and a machine the book describes -- as ix's
  TinyMachine is.
- **Singularity** (Microsoft Research, 2003-10; from memory): a kernel
  and processes in Sing#, a C# with contracts; a collector per
  process, processes isolated by the language instead of the MMU
  ("software-isolated processes"), channels between them.
- **House** (Portland State, 2005; from memory): a Haskell system on
  bare x86, its runtime (GHC's) under it, the hardware reached through
  a small monad of primitives -- the typed-views idea of mini-xv6's
  plan, in Haskell.
- **Biscuit** (MIT, OSDI 2018: "The benefits and costs of writing a
  POSIX kernel in a high-level language"; from memory): a POSIX kernel
  in Go, running unmodified Linux programs; the paper measures what
  the collector costs (a few percent, pauses bounded) and how the
  kernel avoids running out of heap in the middle of a system call
  (reserving heap before each). The measured answer to mini-xv6's
  question, at a larger scale.
- **Language-safe kernels without a collector**: Tock, Redox, Theseus
  (Rust, 2010s; from memory): memory safety by ownership instead of a
  collector; a different road to the same end, and more code.

## OCaml without an operating system

- **MirageOS** (Madhavapeddy et al., Cambridge, 2013-; from memory):
  unikernels -- an OCaml program and the libraries it needs, linked
  with the OCaml runtime into one image that runs on a hypervisor
  (Xen, and on bare virtual hardware through Solo5) with no operating
  system under it. Its `ocaml-freestanding` builds the runtime against
  a minimal C library, as `kernel/step1/libc.c` does; but a unikernel
  runs one program, it is not a kernel for others'.
- **The OCaml runtime's own ports**: its systhreads library (threads,
  each with a stack the collector scans through a hook in `roots.c`:
  what mini-xv6's step 3 needs) and OCaml 5's effects and fibers (the
  runtime switching stacks itself; from memory: OCaml 5.0, 2022).
- **~/xix/kernel** (the author, 2017; surveyed 2026-09-25): a Plan-9-like
  kernel in OCaml on the Pi2, bytecode interpreted by ocaml-light's
  runtime, started last by a C Plan 9 kernel doing the low-level work;
  printing and green threads switched by the timer worked, the
  OCaml kernel (3,300 lines) never ran a process. mini-xv6's plan
  puts a user program first because of it.
- Other OCaml kernel experiments (from memory, to check): **Funk**
  (2000s, an OCaml kernel on x86) and the OCaml ports to microcontrollers
  (OMicroB, bytecode on AVR and ARM Cortex-M, 2010s).

## xv6 and its descendants

- **xv6** (Cox, Kaashoek and Morris, MIT, 2006-; from memory): Unix V6
  rewritten for teaching, x86 then RISC-V, with its commentary. The
  specification mini-xv6 follows.
- **Its ARM ports** in xv6-multiarch (`~/xv6/forks`, checked): Zhiyi
  Huang's arm-pi1 for the Pi1 (the one mini-xv6 twins: its user
  programs and `fs.img` format), and the others (notes_pi_related_work.md).
- **xv6 in other languages** (from memory): rv6 and octox (Rust),
  ports to Go and others as course projects.
- **tiny-os v6** (`tiny/tiny-os/v6/`, ix, 2026): xv6 simplified, in 2,600
  lines of C compiled by tiny-c for TinyMachine: the C kernel mini-xv6
  is compared with in size and clarity (plan_kernel.md).

## Where mini-xv6 sits

Between Biscuit (a real POSIX kernel in a collected language, large)
and Oberon (a whole small system in one), on a real machine as House
was, with OCaml as Mirage runs it (a freestanding runtime), and xv6's
design and user programs as its specification and its test.
