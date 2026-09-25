# Related work: full-system emulation, and operating systems on the Pi

Where mini-qemu ([`plan_pi.md`](../plans/plan_pi.md),
[`notes_pi.md`](../tutorials/notes_pi.md)) sits. The user-mode side
is in [`notes_arm_related_work.md`](notes_arm_related_work.md). Names
and dates not read here are **from memory**, marked, to check before
they are quoted in a `.mli`.

## Full-system emulators

- **SimOS** (Rosenblum et al., Stanford, 1995-97; from memory): a
  whole machine, fast enough to boot IRIX, with interchangeable CPU
  models from fast translation (Embra) to detailed timing: the idea
  that one emulator can trade speed for fidelity.
- **Bochs** (1994-; from memory): an x86 PC interpreted, in C++,
  portable, slow, exact; the teaching and debugging machine of many OS
  courses.
- **QEMU**'s system mode (Bellard, 2003-; from memory): the machine
  models, boards and devices around the translating CPU; its **raspi**
  machines (`raspi0`, `raspi1ap`, `raspi2b`, `raspi3ap`, `raspi3b` in
  QEMU 8.2, checked here; `raspi4b` from QEMU 9.1, per xv6
  arm64-pi4's README, and in the QEMU 11.1 built here, checked)
  emulate the BCM283x devices a kernel needs, some partially -- 9pi
  works around its watchdog, framebuffer blanking, mini UART and USB
  (principia's `usbdwc.c`, `emulating()`, checked).
- **TinyEMU** (Bellard, 2017-19; from memory): RISC-V and x86 machines
  in a few thousand lines, virtio for disks and network: the proof that
  a complete, bootable system emulator can be small and readable.
- **gem5**, **Simics** (from memory): the architecture researchers'
  and the industry's detailed simulators; far larger than a tiny one.
- Hardware virtualization (VMware, KVM, Firecracker; principia's
  lineage.txt, checked) runs the guest on the real CPU: not emulation,
  and not available for a Pi's ARM1176 on this host.

## Several cores in one emulator

- **Round-robin in one thread**: QEMU's TCG ran all of a machine's
  cores that way until its multi-threaded TCG (MTTCG, QEMU 2.9, 2017;
  from memory), a slice of instructions each -- mini-qemu's decision 3.
  Simple and repeatable; a core that spins costs its whole slice.
- **A thread per core** (MTTCG): fast on a multicore host, and as
  nondeterministic as the hardware: QEMU's raspi4b prints xv6's "hart
  N starting" lines in a different order from run to run, and starts
  an ELF's four cores into a race (notes_pi.md, section 6) that
  xv6 wins by timing.
- **Time from instructions**: QEMU's `-icount` (from memory) makes the
  guest's clock advance with the instructions run, so a run replays
  exactly; mini-qemu's clock is only that (decision 6). Simics
  (Wind River; from memory) made determinism the product: a whole
  machine replayed, run backwards.
- **Idle detection**: emulators and hypervisors skip a core's time
  when it executes WFI (QEMU halts the vCPU, KVM exits to the host);
  detecting a *spinning* core, which xv6's idle loop is, is harder and
  heuristic (pause-loop exiting in Intel's VT-x, from memory).

## Operating systems on the Raspberry Pi

- **Plan 9 on the Pi** (Richard Miller's `bcm` port, 2012-13; from
  memory): the origin of principia's 9pi; 9front carries it on, and
  adds a 64-bit kernel for the Pi3 and Pi4 (`bcm64`, from memory).
- **xv6** (Cox, Kaashoek and Morris, MIT, 2006-; from memory): Unix V6
  rewritten for teaching, x86 then RISC-V; its Pi ports, gathered with
  git history in xv6-multiarch (`~/xv6`, `docs/provenance.md`,
  checked): Zhiyi Huang's for the Pi1 and Pi2 (arm-pi1, arm-pi2),
  inaciose's (arm, arm-pi1-bis), patha454's four-core AArch32 port for
  the Pi3 (arm-pi3), and k-mrm's AArch64 port for the Pi4 (arm64-pi4)
  -- all booting under QEMU with `usertests` passing, mini-qemu's
  acceptance tests.
- **Linux** (Raspberry Pi OS): the Pi's usual system, and a device-tree
  kernel -- heavier to emulate than 9pi, which needs no device tree.
- Teaching: Cambridge's "Baking Pi" bare-metal course (2012; from
  memory), the many "OS on the Pi" tutorials, and xv6's ports to ARM
  (from memory): bare-metal Pi programming as an OS course's lab --
  TinyMachinePi.ml's intended reader.
- **Circle** (from memory): a C++ bare-metal environment for the Pi,
  with drivers for its devices; a readable second source for their
  registers.

## The documents

- **BCM2835 ARM Peripherals** (Broadcom, 2012; from memory, with its
  errata kept by the community): the Pi1's devices, register by
  register; the BCM2711 document for the Pi4.
- **ARM1176JZF-S Technical Reference Manual** and the ARMv7-A ARM
  (ARM DDI 0406; from memory): modes, CP15, the short-descriptor MMU.
- **ARMv8-A ARM** (ARM DDI 0487; from memory): exception levels,
  system registers, translation tables.
- **ARM GIC Architecture Specification v2** (IHI 0048; from memory)
  and the GIC-400's TRM: the Pi4's interrupt controller; QEMU's
  `hw/intc/arm_gic.c` (read) for what the kernels see of it.
- The Pi firmware's **mailbox property interface** (the Raspberry Pi
  firmware wiki; from memory): the tags 9pi sends.

## Where mini-qemu sits

Between QEMU's raspi machines, which it is tested against, and
TinyEMU, whose size it aims at: two Pis, the Pi1 as 9pi and xv6 use it
and the Pi4 as xv6 arm64-pi4 does, in OCaml, the CPU cores mini-5i's,
the devices small state machines behind a bus, the cores in turn,
deterministic time. Its free variant, TinyMachinePi.ml, is the smallest
machine a kernel can boot on.
