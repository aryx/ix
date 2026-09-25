(* mini-xv6 (plan_kernel.md): xv6 in OCaml, one kernel on two boards,
 * the Raspberry Pi 1 (ARMv6, arm32) and the Pi 4 (ARMv8, arm64), each
 * running its xv6 port's own user programs from that port's own fs.img
 * (xv6-multiarch's arm-pi1, arm64-pi4): init, sh, the utilities,
 * usertests. One xv6, xv6-riscv's semantics: the ports converging.
 *
 * The kernel: Types (the data), Machine (the board's machine.c's
 * primitives), Arch (what else differs between the boards), Mmu
 * (pages and address spaces), Proc (processes, sleep and wakeup, the
 * scheduler), Fs (the file system, in place on the RAM disk), File
 * (open files, pipes, the console), Exec, Syscall; this module handles
 * the traps start.s and machine.c hand to OCaml ("trap", "irq",
 * "fault", "process_start") and boots: the timer, the UART's input, the
 * first process, which runs /init (xv6's initcode, done by the kernel),
 * then the scheduler, forever.
 *
 * Built up in kernel/step1-5/ (on the Pi1): OCaml bare-metal, user mode and
 * system calls, processes on their own kernel stacks (the collector
 * seeing them all), the MMU, the timer. *)
