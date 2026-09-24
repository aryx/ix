# Plan: TinyRaspberryPi, a Raspberry Pi emulator, Pi1 then a 64-bit Pi (`raspberry/`)

Companions: [`notes_pi.md`](../tutorials/notes_pi.md), the tutorial
(the SoC and its buses; ARM's privileged state: modes, banked
registers, exceptions, CP15; the MMU's page tables; the devices a
kernel needs: interrupt controller, timers, UART, mailbox and
framebuffer, SD card; how 9pi boots; AArch64's exception levels and
translation tables), and
[`notes_pi_related_work.md`](../related-work/notes_pi_related_work.md)
(full-system emulation from SimOS and Bochs to QEMU's raspi machines
and TinyEMU; operating systems on the Pi).

It builds on [`plan_arm.md`](plan_arm.md): TinyArm's CPU cores
(`machine/`: `Arm32`, `Arm64`, `Memory`'s bus), extended with the
privileged state, and devices behind the bus. It is written now, with
plan_arm.md, so that the cores are designed for it; it starts once
TinyArm's phases 1-5 are done.

The twin is QEMU's raspi machines (`qemu-system-arm -M raspi1ap`,
`raspi2b`; `qemu-system-aarch64 -M raspi3b`; QEMU 8.2 here), for
behaviour. The program it must run is principia's Raspberry Pi kernel,
**9pi** (`kernel/`, `conf/arm/pi` and `pi2`, about 12,500 lines, the
Kernel book), which boots under `qemu-system-arm -M raspi1ap`
(principia's `mkfile-target-pi`, checked).

The author asked for it ("later on do another tiny but for the
Raspberry Pi that rely on the ARM emulator but extended for the
qemu-system-part with MMU, framebuffer, storage"; "emulate after the
Pi1 and Pi4").

## Context

A Raspberry Pi is a system on a chip: an ARM core, RAM, and devices at
fixed physical addresses (Broadcom's BCM2835 for the Pi1). A system
emulator runs the machine's first instruction as the firmware leaves
it, and everything else is the guest's: the kernel sets up the MMU,
takes interrupts from the timer, writes to the UART, draws in the
framebuffer, reads the SD card. The emulator must then do what the
hardware does for each of those, and no more: a device only as far as
the kernel uses it.

Why this way:

- **9pi says what a Pi1 must be** (principia's kernel, surveyed): an
  ARM1176 (ARMv6) with processor modes, banked registers, high
  vectors, CP15 (the MMU with 1 MB sections and 4 KB pages, caches
  and TLB as operations), VFP; and eight devices, at offsets from
  0x20000000 (Pi1's physical I/O, 0x7E000000 on the bus): the system
  timer (+0x3000), DMA (+0x7000), the interrupt controller (+0xB200),
  the ARM timer (+0xB400), the VideoCore mailbox (+0xB880: the
  property channel and the legacy framebuffer channel), the power
  manager and watchdog (+0x100000), GPIO (+0x200000), the mini UART
  (+0x215000), the EMMC SD controller (+0x300000), and USB (+0x980000,
  optional). No ATAGs, no device tree (9pi's `ataginit` is commented
  out): the RAM size comes from the mailbox.
- **QEMU boots the same image**: `-M raspi1ap -device loader,
  file=9pi,addr=0x8000,force-raw=on`; so the console output of a boot
  is comparable, line by line, and qemu's `-d in_asm,cpu` log gives the
  state instruction by instruction for the first differences.
- **The cores are shared.** TinyArm's `Arm32` and `Arm64` gain what
  user mode did not need (the CPSR's mode bits and the banked
  registers, exceptions, system instructions), behind the same
  variants; user mode keeps working, tested as before.

## Principles

Those of [`../README.md`](../README.md), and:

- **The kernel decides the devices.** 9pi's drivers are the
  specification: each register it reads or writes is emulated, others
  are logged ("unemulated device register ADDR") and read as zero.
  Principle 1 becomes: every device behaviour 9pi (and, for arm64, the
  chosen kernel) relies on.
- **QEMU for the machine, the ARM manuals for the CPU.** The boot log
  and qemu's instruction trace are compared; where QEMU and the
  hardware documents disagree (9pi works around QEMU's watchdog,
  framebuffer blanking, mini UART and USB: `emulating()` in
  `usbdwc.c`), 9pi's view of QEMU is kept, and noted.
- **Devices are small state machines behind the bus.** A device is a
  record: its address range, a load and a store function, an optional
  tick (timers), and an interrupt line; `Memory`'s bus dispatches by
  address. No device knows the CPU.

## The interface

```
tinypi [-M pi1|pi2|pi3] [-sd card.img] [-fb out.ppm] [-t] kernel
```

The console (the mini UART, or the PL011 on 64-bit Pis) is standard
input and output; the framebuffer is written to a PPM file on request
(a signal, or at exit) until ix has a window system (the Graphics
book's); the SD card is an image file.

## Target layout

```
machine/ (extended)
  Arm32.ml, Arm64.ml         + modes, banked registers, SPSR, exceptions,
                             MRS/MSR/CPS/RFE/SRS, LDREX/STREX, MCR/MRC
  Mmu32.ml(i)                ARMv6/v7 short descriptors: sections,
                             coarse tables, small pages; domains, faults
  Mmu64.ml(i)                AArch64 4 KB granule, 4 levels (phase C)
  Vfp.ml(i)                  VFPv2 for 9pi's floating point
raspberry/                   library ix_raspberry; the tinypi executable
  Soc.ml(i)                  the machine: RAM, the bus's map, the loop
  Intc.ml(i)                 BCM2835 interrupt controller (Pi1, Pi2)
  Timer.ml(i)                system timer, ARM timer (Pi1, Pi2); generic
                             timer (Pi2+)
  Uart.ml(i)                 mini UART (and GPIO's alternate functions);
                             PL011 (64-bit Pis)
  Mailbox.ml(i)              the property channel; the framebuffer
  Emmc.ml(i), Dma.ml(i)      the SD card, and the DMA that feeds it
  Gic.ml(i)                  GIC-400 (Pi4)
  CLI.ml(i), Main.ml
tiny/TinyPi.ml               the free variant (see "Outside QEMU")
```

**The size target**: the core extensions 900 (Arm32 privileged 350,
Mmu32 250, Vfp 300), Soc 200, Intc 120, Timer 150, Uart 150, Mailbox
200, Emmc+Dma 400, CLI 100: **about 2,200 lines for the Pi1**; the
64-bit machine another 1,500 (Arm64 privileged 400, Mmu64 300, Gic
250, PL011 100, generic timer 100, the rest shared). QEMU's raspi
machines and the BCM2835 devices they use are some 10,000 lines of C
(from memory: to count in phase A).

## Groundwork decisions

### 1. Privileged state inside the same variants

The CPSR becomes the architecture's: N Z C V, the I and F interrupt
masks, the mode (USR, FIQ, IRQ, SVC, ABT, UND, SYS). Registers r13
and r14 are banked per mode (r8-r12 too for FIQ): the register file is
the current mode's view, and a mode change saves and loads the banks,
so the common path (no mode change) costs nothing. An exception is a
function: save CPSR in the new mode's SPSR, set LR, change mode, mask
interrupts, jump to the vector (0x0 or 0xffff0000: 9pi uses high
vectors).

### 2. The MMU as a bus in front of the bus

With the MMU off, the bus is physical. On, every access is translated:
a small TLB (a hash table of 1 MB and 4 KB mappings) in front of the
walk; a miss walks the L1 table (and the L2 for coarse entries);
permission and domain checks; a fault raises a data or prefetch abort
with FSR and FAR set. The TLB is flushed where the kernel says so
(CP15 c8 operations), and the decode cache (plan_arm.md decision 5) is
keyed by physical address, flushed on I-cache invalidations (c7).
Caches themselves are not emulated: their operations are no-ops.

### 3. Time: counted instructions, not the host's clock

The system timer counts microseconds; the emulator advances it by
instructions executed (a fixed rate, e.g. 1 instruction = 1 ns at a
nominal 1 GHz, adjustable), so a run is deterministic (principle 6)
and repeatable against itself; an option lets it follow the host's
clock for interactive use. Interrupts are checked between
instructions.

### 4. Devices by 9pi's use, not by the datasheet

Each device implements the registers 9pi touches, with the behaviour
9pi relies on (for the mailbox: the property tags it sends, `getram`,
`getfwrev`, `setpower`, clock rates, the framebuffer; for EMMC: the
commands of SD initialisation and block reads and writes through
DMA). The BCM2835 ARM Peripherals document (Broadcom, 2012; from
memory) and QEMU's sources are the reference for each register's
meaning; 9pi's driver for which ones matter.

### 5. The 64-bit Pi: raspi3b now, Pi4 when there is a reference

QEMU 8.2 has `raspi3b` (BCM2837, Cortex-A53) but not `raspi4b`
(QEMU 9.0, from memory), and principia has no arm64 Pi kernel. Phase
C targets the Pi3 under QEMU 8.2 with a kernel to choose (9front's
64-bit Pi kernel, `bcm64`, which runs on the Pi3 and Pi4, from
memory; or a Linux kernel; or, later, ix's own TinyKernel); the Pi4
(BCM2711, Cortex-A72, GIC-400, peripherals at 0xFE000000, from memory)
follows when a QEMU with `raspi4b` or a real board is available to
compare with. The differences Pi3 to Pi4 are the interrupt controller
(the Pi3's BCM2836 local controller against the Pi4's GIC-400) and the
addresses.

## Phases

- **A. Pi1.**
  1. Arm32's privileged state (decision 1), MRS/MSR/CPS, exceptions;
     unit tests against the ARM ARM's pseudocode cases.
  2. The Soc, RAM, the bus's map; the mini UART and GPIO; boot to
     9pi's first console line.
  3. CP15 and the MMU (decision 2); high vectors.
  4. Interrupt controller, system and ARM timers: the clock ticks.
  5. The mailbox: RAM size, firmware revision, the framebuffer.
  6. EMMC and DMA: 9pi mounts its root from the SD image.
  7. VFP (9pi's `vfp3`: user programs' floating point).
  Checked at each step: the boot's console output against
  `qemu-system-arm -M raspi1ap`, and qemu's instruction trace for the
  first divergence.
- **B. Pi2** (Cortex-A7, ARMv7, 9pi's `pi2` configuration, QEMU's
  `raspi2b`): ARMv7's instructions, the generic timer, the ARM-local
  interrupts and mailboxes; one core first, SMP after.
- **C. The 64-bit Pi**: Arm64's exception levels, system registers,
  Mmu64, a Pi3 under QEMU 8.2 with the chosen kernel; then the Pi4.
- **D. `tiny/TinyPi.ml`.**

## Outside QEMU: TinyPi.ml

Free, in one file: the smallest machine a kernel can run on -- an ARM
core subset, RAM, a UART, a timer and an interrupt line, no MMU (or
sections only) -- and a kernel of a page of assembly for it, printing
and taking timer interrupts; the machine a first operating-systems
course would want (TinyEMU's spirit, in OCaml). Checked by its laws:
the kernel's output, the interrupts' count per simulated second.

## Verification

`make test-pi` (needs QEMU and the 9pi image): the boot's console
against QEMU's; the MMU's walks against hand-built tables; the
devices' registers against 9pi's expectations, driver by driver.

## Status

2026-09-24: plan written, with plan_arm.md; starts after TinyArm's
phases 1-5.
