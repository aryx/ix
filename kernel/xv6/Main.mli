(* mini-xv6 (plan_kernel.md): xv6 in OCaml, on the Raspberry Pi 1, running
 * xv6 arm-pi1's own user programs from its own fs.img: init, sh, the
 * utilities, usertests.
 *
 * The kernel: Types (the data), Machine (machine.c's primitives), Mmu
 * (pages and address spaces), Proc (processes, sleep and wakeup, the
 * scheduler), Fs (the file system, in place on the RAM disk), File
 * (open files, pipes, the console), Exec, Syscall; this module handles
 * the traps start.s and machine.c hand to OCaml ("trap", "irq",
 * "fault", "process_start") and boots: the timer, the UART's input, the
 * first process, which runs /init (xv6's initcode, done by the kernel),
 * then the scheduler, forever.
 *
 * Built up in kernel/step1-5/: OCaml on the bare Pi1, user mode and
 * system calls, processes on their own kernel stacks (the collector
 * seeing them all), the MMU, the timer. *)
