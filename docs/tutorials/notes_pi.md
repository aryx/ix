# A Raspberry Pi emulator, from scratch: a tutorial for `raspberry/`

What a system emulator adds to a user-mode one, and how to build a
Raspberry Pi good enough to boot principia's kernel, 9pi, and xv6's
six Pi ports: the machine
as a CPU, RAM and devices at addresses; ARM's privileged state (modes,
banked registers, exceptions); the coprocessor that controls the MMU,
and the page tables it walks; the devices a kernel needs and nothing
more; then the 64-bit Pi. Written for **a reader of TinyRaspberryPi's
code**, before the code, as the specification of
[`plan_pi.md`](../plans/plan_pi.md). It follows
[`notes_arm.md`](notes_arm.md), whose CPU cores it extends. Related
systems: [`notes_pi_related_work.md`](../related-work/notes_pi_related_work.md).

The Pi1 facts below are 9pi's (principia's `kernel/`, read), and
QEMU's (`qemu-system-arm -M raspi1ap`, which boots it); those marked
from memory are to check against the BCM2835 and ARM documents before
they are quoted in code.

## 1. What a system emulator is

A user-mode emulator runs one program and answers its system calls. A
system emulator runs the whole machine from its first instruction: the
kernel, then the programs the kernel runs, and it answers nothing --
the kernel does. What it must provide instead is what the kernel
touches:

```
   the CPU            + privileged state: modes, exceptions, CP15
   memory             RAM, and the MMU's translation in front of it
   devices            registers at physical addresses: reading and
                      writing them is how a kernel talks to hardware
   time               a clock that advances; interrupts that arrive
```

## 2. The Pi1 as 9pi sees it

A BCM2835 system on a chip: one ARM1176JZF-S core (ARMv6, with VFP),
512 MB of RAM (the mailbox says how much), and devices in a 16 MB
window at physical 0x20000000 -- which the chip's own documentation
calls 0x7E000000, **the bus address** (the VideoCore GPU's view), a
confusion every Pi kernel meets: 9pi maps the window at virtual
0x7E000000 so that its drivers use the documented addresses.

```
   physical      bus           9pi's name     what
   0x20003000    0x7E003000    system timer   1 MHz counter, 4 compares
   0x20007000    0x7E007000    DMA            channel 4 feeds the SD card
   0x2000B200    0x7E00B200    interrupts     pending, enable, disable
   0x2000B400    0x7E00B400    ARM timer      a free-running counter
   0x2000B880    0x7E00B880    mailbox        to the GPU: RAM size, clocks,
                                              power, the framebuffer
   0x20100000    0x7E100000    power/watchdog
   0x20200000    0x7E200000    GPIO           pins' functions (the UART's)
   0x20215000    0x7E215000    AUX, mini UART the console
   0x20300000    0x7E300000    EMMC           the SD card
   0x20980000    0x7E980000    USB (DWC OTG)  keyboard, Ethernet: optional
```

How 9pi boots: the GPU's firmware loads the kernel at physical 0x8000
and starts the ARM there (no ATAGs, no device tree used: 9pi's
`ataginit` is commented out). `_start` switches to SVC mode with
interrupts off; `armstart` turns the MMU and caches off, invalidates
them, builds the page table, turns the MMU on with high vectors, and
jumps to `main` at its virtual address (the kernel is linked at
0x80008000: virtual 0x80000000 is physical 0, KZERO). `main` asks the
mailbox for the RAM size, starts the console on the mini UART,
initialises the framebuffer, the traps, the clock, and goes on.

## 3. ARM's privileged state

**Modes.** The CPSR's low five bits say who is running: USR (0x10) for
programs; SVC (0x13) for the kernel after a system call; IRQ (0x12)
and FIQ (0x11) for interrupts; ABT (0x17) after a memory fault; UND
(0x1b) after an undefined instruction; SYS (0x1f), privileged with the
user's registers. Bits 7 and 6 (I, F) mask interrupts.

**Banked registers.** Each mode but SYS has its own r13 (sp) and r14
(lr), and FIQ its own r8-r12 as well: an interrupt handler has a stack
without saving anything. An emulator keeps the banks and swaps them at
a mode change -- rare -- so that the common path reads `r.(13)` as
before.

**Exceptions.** When something happens (a system call, an interrupt,
a fault, an undefined instruction), the CPU: saves the CPSR in the new
mode's **SPSR**, puts a return address in the new mode's lr, switches
mode, masks IRQ, and jumps to a vector:

```
   0x00 reset   0x04 undefined   0x08 svc   0x0c prefetch abort
   0x10 data abort   0x18 irq   0x1c fiq       (+0xffff0000: high vectors)
```

The handler returns by restoring the CPSR from the SPSR and the pc
from lr (`movs pc, lr`, or `rfe` on ARMv6, which 9pi uses). An
undefined instruction is how 9pi's floating point is reached when VFP
is off: the trap handler (`fpuemu`) emulates it.

**CP15**, the system control coprocessor, is reached by `mcr`/`mrc`:
c1 the control register (MMU on, caches on, high vectors), c2 the
translation table's base, c3 the domains' access, c5/c6 the fault's
status and address, c7 cache operations, c8 TLB operations. For an
emulator, c7 and c8 are mostly "forget what you cached".

## 4. The MMU: ARMv6's short descriptors

A virtual address is translated by walking a table in RAM:

```
   L1: 4096 entries of 4 bytes (16 KB), indexed by VA[31:20]
       entry & 3 = 0   fault
                   1   a coarse L2 table, at entry[31:10]
                   2   a 1 MB section: physical entry[31:20] | VA[19:0]
       L2 (coarse): 256 entries, indexed by VA[19:12]
       entry & 2 = 2   a 4 KB small page: entry[31:12] | VA[11:0]
```

with access bits and a domain in each entry, checked against the
current mode (a user access to a kernel-only page faults: a data
abort, FSR saying why, FAR where). 9pi maps all RAM at 0x80000000 with
sections, the device window at 0x7E000000 uncached, the vector page at
0xffff0000 through a coarse table, and user memory with 4 KB pages.
The emulator's TLB remembers walks by page; `mcr` to c8 flushes it,
and the decode cache, keyed by physical address, is flushed by c7's
I-cache invalidation.

## 5. The devices

Each device is registers at addresses: a read or a write is a
function call into the device's model.

- **Interrupt controller** (0x7E00B200): a pending register per bank of
  sources, enable and disable registers (writing a 1 enables or
  disables that source). The CPU takes an IRQ when a source is pending
  and enabled and the CPSR's I bit is clear. 9pi's numbers: the timer
  is 3, USB 9, AUX (the UART) 29, the SD controller 62; the ARM timer
  64.
- **System timer** (0x7E003000): CLO/CHI a 64-bit microsecond counter;
  four compare registers C0-C3; when CLO equals C3, bit 3 of CS is set
  and interrupt 3 raised; the kernel acknowledges by writing 1<<3 to
  CS and sets the next compare: that is 9pi's clock tick.
- **Mini UART** (0x7E215000, in AUX): a data register (a write sends a
  byte to the console), a line status register (transmitter empty,
  data ready), enable bits; GPIO pins 14 and 15 set to the UART's
  function by the kernel (the emulator can ignore GPIO but log it).
- **Mailbox** (0x7E00B880): a message is the bus address of a buffer
  plus a channel in the low four bits, written when the status says
  not full; the GPU answers in the same buffer. Channel 8, the
  property interface, carries tags (get RAM size, firmware revision,
  set power, clock rates); channel 1 the legacy framebuffer request
  (width, height, depth; the GPU returns the framebuffer's address).
  The emulator plays the GPU: it fills in the answers.
- **Framebuffer**: RAM the kernel draws in; the emulator shows it (a
  window, or a picture written on request).
- **EMMC** (0x7E300000): an SD host controller; the kernel sends SD
  commands (reset, identify, select, set block length, read or write
  blocks) and moves the data by DMA channel 4. Emulated against an
  image file.

## 6. The 64-bit Pi

AArch64 replaces modes by **exception levels**: EL0 (programs), EL1
(the kernel), EL2 (a hypervisor), EL3 (the secure monitor); a Pi's
firmware starts the kernel at EL2 (from memory), which drops to EL1.
An exception saves the state in SPSR_ELn and the return address in
ELR_ELn, puts the reason in ESR_ELn, and jumps into a table at
VBAR_ELn: 16 entries of 128 bytes (from the current level or a lower
one, using SP0 or SPx, synchronous or IRQ or FIQ or SError).
Translation walks up to four levels of 512-entry tables with 4 KB
pages (VA bits 47:39, 38:30, 29:21, 20:12), configured by TCR_EL1 and
TTBR0/1_EL1, memory types by MAIR_EL1, enabled by SCTLR_EL1 (from
memory, all: the ARM ARM for ARMv8-A to check). The Pi3 (BCM2837,
Cortex-A53) keeps the Pi2's devices at 0x3F000000 and a local
interrupt controller at 0x40000000; the Pi4 (BCM2711, Cortex-A72) has
a GIC-400 and its peripherals at 0xFE000000 (from memory).

## 7. xv6 on the Pis

xv6 (MIT's teaching Unix, a rewrite of Unix V6 for x86 and then
RISC-V) has six Raspberry Pi ports in xv6-multiarch (`~/xv6/forks`),
each booting under QEMU to a shell and passing its `usertests`. Their
needs overlap 9pi's, with differences worth knowing:

- **The console is the PL011** (UART0, +0x201000), not the mini UART:
  QEMU's raspi1ap gives the mini UART no backend.
- **The file system is a ramdisk linked into the kernel**: no SD card.
- **Two MMU formats on 32 bits.** arm-pi1 turns the MMU on without
  SCTLR's XP bit: ARMv6's *legacy* descriptors (subpages, ARMv5's
  access bits); the ARMv7 ports set it, and xv6 `arm` also splits the
  address space between two tables (TTBCR.N = 4: user addresses below
  256 MB through TTBR0, the kernel's through TTBR1).
- **A 64-bit stub for a 32-bit kernel.** On raspi3b, QEMU starts the
  core in AArch64 at EL2; arm-pi3's `armstub64` clears HCR_EL2.RW (the
  level below runs AArch32), puts AArch32 SVC in SPSR_EL2 and the
  kernel's address in ELR_EL2, and `eret`s: from then on the core
  decodes AArch32. The 32-bit registers are the low halves of x0-x14:
  one core, two instruction sets.
- **Several cores.** arm-pi3 and arm64-pi4 start four: the secondary
  cores wait, polling a *spin table* (addresses 0xe0, 0xe8, 0xf0) for
  an entry point, and `sev` wakes them; locks are `ldrex/strex` (arm32)
  or `ldaxr/stlxr` (AArch64), exclusive accesses that fail if another
  core wrote in between.
- **The Pi4** replaces the BCM2835 interrupt controller by an ARM
  **GIC-400** (a distributor for shared interrupts, a CPU interface per
  core, private interrupts per core such as the timer's PPI 27) and the
  system timer by the **generic timer** (system registers CNTV_CTL,
  CNTV_TVAL, counting at CNTFRQ).
- **Where QEMU loads a kernel**: a raw image at 0x10000 (raspi1ap,
  raspi2b), 0x80000 (raspi3b, raspi4b) -- not the 0x8000 of the real
  firmware; the ports' QEMU builds are linked for it.

## 8. QEMU's Pi and the real Pi

QEMU's raspi machines are close to the boards, not equal, and the
kernels know it: they read the USB controller's id, see QEMU's, and
take other paths. Where QEMU loads a kernel (0x10000, 0x80000), the
board's firmware loads it from the SD card's FAT partition as
`config.txt` says (`kernel.img` at 0x8000 on a Pi1, `kernel7.img` on a
Pi2, `kernel8.img` at 0x80000 on a Pi4), and starts the core in
another state: HYP mode on a Pi2, EL2 on a Pi4, with the address of
ATAGs or a device tree in r2 or x0. The firmware answers the mailbox
with bus addresses where QEMU gives physical ones, drives a hub
(LAN9512/9514) between the USB controller and the ports, answers a
power handshake on channel 0 QEMU never answers. An emulator meant as
a stepping stone to the boards must do what the boards do; QEMU's
behaviour is kept too, for comparing with QEMU (plan_pi.md, decision
8).

## 9. How TinyRaspberryPi will be tested

xv6's ports' own tests, unchanged, with TinyRaspberryPi in QEMU's
place: boot, a shell prompt, `ls`, `usertests` to "ALL TESTS PASSED".
For 9pi, the same kernel image under QEMU and under TinyRaspberryPi:
the console output compared line by line; QEMU's instruction trace
(`-d in_asm,cpu`) against TinyRaspberryPi's `-t` for the first
divergence; each device's registers checked against what 9pi's driver
expects of them.

## 10. Exercises

- A second core (the Pi2): what must be shared, what per core; the
  ARM-local mailboxes that start the other cores.
- USB, well enough for a keyboard.
- An emulated clock that follows the host's time; what breaks.
- Snapshot and restore of the whole machine (registers, RAM, devices).
