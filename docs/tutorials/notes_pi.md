# A Raspberry Pi emulator, from scratch: a tutorial for `raspberry/`

What a system emulator adds to a user-mode one, and how to build a
Raspberry Pi good enough to boot principia's kernel, 9pi, and xv6's
six Pi ports: the machine
as a CPU, RAM and devices at addresses; ARM's privileged state (modes,
banked registers, exceptions); the coprocessor that controls the MMU,
and the page tables it walks; the devices a kernel needs and nothing
more; then the 64-bit Pi. Written for **a reader of mini-qemu's
code**, first before the code, as the specification of
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

The Pi4 (BCM2711, four Cortex-A72 cores) as QEMU's raspi4b models it
and xv6 arm64-pi4 uses it: `machine/Arm64`'s privileged state,
`machine/Mmu64`, and `raspberry/`'s `Gic` and `Pi4` (plan_pi.md, phase
G). Its peripherals are at 0xFE000000 (the PL011 at 0xFE201000), its
interrupt controller at 0xFF841000.

**Exception levels replace modes.** EL0 runs programs, EL1 the kernel,
EL2 a hypervisor, EL3 the secure monitor; CurrentEL says which. Under
QEMU an ELF kernel starts at EL3 (the Pi4's firmware would hand it over
at EL2), and xv6 walks down itself: it sets SCR_EL3 (the level below
is AArch64, non-secure), puts EL2 in SPSR_EL3 and its next label in
ELR_EL3, `eret`s; then the same with HCR_EL2, SPSR_EL2 (EL1, the four
interrupt masks set) and ELR_EL2. An `eret` is the only way down, an
exception the only way up.

**An exception** saves PSTATE in SPSR_ELn (the flags N Z C V in bits
31-28, the masks D A I F in 9-6, the level in 3-2, SPSel in 0) and the
return address in ELR_ELn, and jumps into the table at VBAR_ELn: four
groups of four 128-byte entries (synchronous, IRQ, FIQ, SError), the
group by where the exception comes from -- the same level on SP_EL0
(+0x000), the same level on its own stack (+0x200), a lower level
(+0x400; +0x600 when that level is AArch32). ELR is the instruction to
retry for a fault or an interrupt, the next one for an `svc`.

**Each level has its stack pointer.** SP_EL0 is the programs'; SP_EL1
the kernel's, used when SPSel is 1 (an exception sets it). mini-qemu
keeps the current one in register slot 31 and the others aside,
swapped when the level or SPSel changes -- as mini-5i's arm32 banks
r13 and r14 per mode, so the common path pays nothing.

**Why it happened: ESR.** A synchronous exception writes its syndrome
to ESR_ELn: the class (EC, bits 31-26: 0x15 an `svc` from AArch64, 0x24
a data abort from a lower level, 0x25 from the same one, 0x20 and 0x21
the instruction aborts, 0 an undefined instruction), IL (bit 25, a
32-bit instruction), and the class's details (ISS): for an abort, the
fault status code -- translation 0x4, access flag 0x8, permission 0xc,
plus the level of the table where the walk stopped -- and WnR (bit 6),
a write. FAR_ELn holds the faulting address. usertests' MAXVAplus
writes to 0x8000000000000000, 0xc000..., ... 0xffffffc000000000 and
xv6 prints each child's ESR and FAR: `0x92000044` (EC 0x24, IL, WnR,
translation at level 0: the address is in neither half, below),
`0x92000045` (level 1), `0x92000047` (level 3). mini-qemu prints
QEMU's 64 lines exactly; getting the level right is the test.

**System registers** (SCTLR, TCR, TTBR0/1, MAIR, VBAR, ESR, the
timer's...) are read by `mrs` and written by `msr`, named in the
instruction by five fields (op0, op1, CRn, CRm, op2). There are
hundreds; `Arm64` decodes the sixty the kernels use, by a table that
also gives objdump's names, and leaves the rest undefined. Two reasons:
an undefined one is loud (the kernel takes an exception, `-d` says
which word), and the decoder stays checkable against objdump on
random words -- a register it does not know it does not print wrongly.
A register of a level above the current one is undefined too: EL1's
are out of EL0's reach but for those with op1 = 3 (the flags, the
counters, TPIDR_EL0).

**Translation: two halves.** TCR_EL1's T0SZ and T1SZ say how many top
bits of an address must be all zeros (then TTBR0's tables translate
it: the program's) or all ones (TTBR1's: the kernel's). xv6 sets both
to 25: 39-bit halves, the kernel at 0xffffff8000000000, programs from
0; anything between faults at level 0. With 4 KB pages each level's
table has 512 entries and resolves 9 bits (a 39-bit half starts at
level 1, VA bits 38-30, then 29-21 and 20-12). An entry is invalid
(bit 0 clear), a table (bits 1-0 = 11, above level 3), a block (01:
1 GB at level 1, 2 MB at level 2, as xv6 maps its kernel) or a page
(11 at level 3). A leaf's bits: AF (10, the access flag: clear, the
first access faults, the kernel's cue for "used"), AP (7-6: read-only,
EL0 allowed), PXN and UXN (53, 54: not executable at EL1, at EL0). Two
rules that are easy to miss (QEMU's ptw.c has them): what EL0 can
write, EL1 can never execute; what EL0 cannot read, it cannot execute.

**The GIC-400** replaces the BCM2835 controller: a *distributor*
(shared by the cores: which interrupts are enabled, pending, their
priorities, which cores a shared one targets) and a *CPU interface*
per core (the priority mask; IAR, read to acknowledge the highest
pending interrupt, which becomes active; EOIR, written when done).
IDs 0-15 are software interrupts, 16-31 each core's private ones (its
timers: 27 the virtual timer, 30 the physical), 32 and up the shared
devices' (the PL011: 153). The private ones are *banked*: each core
sees its own enable bits at the same address, so a core enabling its
timer's interrupt enables it for itself only -- xv6's gicv2.c notes
the hang when only core 0 did.

**The generic timer** is in the core, reached by system registers: a
counter (CNTPCT, CNTVCT) at CNTFRQ (62.5 MHz on QEMU's cortex-a72; 54
MHz on the board, from memory), and per core two comparators, each a
control (enable, mask, status), a compare value (CVAL) and TVAL, a
signed 32-bit view of CVAL minus the count. xv6 reloads its virtual
timer's TVAL every 100 ms; the interrupt is the line CTL.enable and
count >= CVAL, unmasked.

**Several cores, in turn.** The four cores share the memory and the
devices; each has its registers, its MMU state (TTBR0 differs: each
runs its own process), its timers, and its view of the GIC. mini-qemu
runs them in one thread, a *quantum* of 1,000 instructions each, a
round of turns counting as one quantum of time (the cores run side by
side); a run is repeatable, a race shows up the same way each time.
`wfi` puts a core to sleep until an interrupt, `wfe` until an event
(`sev` from any core); a sleeping core skips its turns, and when all
sleep, the time jumps to the next timer.

**How the other cores start.** On the board, the firmware parks cores
1-3 in a loop: `wfe`, then read a *spin table* slot (0xe0, 0xe8, 0xf0
for cores 1-3) and jump there when it is not zero. The kernel writes
its entry into the slots and executes `sev` (xv6's `cpuN_wakeup`).
QEMU does the same for a Linux kernel (its stub at 0x300), but starts
every core of an ELF kernel at the entry: xv6's secondaries then load
their page tables while core 0 is still building them, and fault. It
works under QEMU because core 0 gets there first, by timing; with
cores taking turns it would not, so mini-qemu parks them as the board
does. A lesson in what "the reference" means: QEMU's behaviour was
kept wherever the kernel's output depends on it, not where it is an
accident.

**Atomics.** A lock is taken by `ldaxr` (load, and watch the address:
the exclusive *monitor*) and `stxr` (store only if the monitor is
still set, and say whether it was). With cores in turn, the monitor is
cleared at every switch: a pair split by a switch fails and loops
again, as it may on hardware.

**What spinning costs.** xv6's idle cores never wait: its scheduler
loops over the process table forever, and the secondaries spin on a
flag while core 0 fills memory at boot. On hardware, or under QEMU's
threads, that is free; interpreted in turns, four cores run xv6 about
four times slower than one (`-smp 1` is mini-qemu's default). A kernel
that `wfi`s when idle would cost nothing more per idle core.

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
- **Several cores.** arm-pi3 and arm64-pi4 start four (section 6: how
  they start, the spin table, `sev`); locks are `ldrex/strex` (arm32)
  or `ldaxr/stxr` (AArch64), exclusive accesses that fail if another
  core wrote in between.
- **The Pi4** replaces the BCM2835 interrupt controller by an ARM
  **GIC-400** and the system timer by the **generic timer** (section
  6).
- mini-qemu boots the Pi1's (arm-pi1, arm-pi1-bis) and the Pi4's
  (arm64-pi4); the Pi2 and Pi3 ports were left out (plan_pi.md,
  "Refocus": one more kernel each, little new to teach).
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

## 9. How mini-qemu is tested

Against QEMU, byte for byte, on the kernels' own consoles
(`raspberry/tests/`): 9pi's boot and a session of commands (`9pi.py`);
the xv6 ports' boots and, with `-u`, their own harnesses running
`usertests` to "ALL TESTS PASSED" (`xv6.sh`); the Pi1's framebuffer
and keyboard through QMP screendumps (`graphics.py`). For the first
divergence, `-trace N` prints the instructions run.

A test's constant can be lowered when the emulator is slow and the
behaviour tested does not depend on it. xv6's kernel touches every
byte of its RAM (PHYSTOP, 128 MB) at boot and in each `usertests` run
(its `countfree`), with byte loops: 21s and 70s here. `xv6_pi4.py`
builds a copy with 4 MB (~/xv6 untouched) and runs 16 of usertests'
tests one by one, each test's output compared with QEMU's running the
same kernel: 75s on one core. The full `usertests` on the real kernel
passes too, in 50 minutes; QEMU's threaded cores take 3.

## 10. Exercises

- A kernel whose idle loop does `wfi`: xv6's scheduler, changed so
  that a pass finding nothing to run waits for an interrupt; measure
  `-smp 4` before and after (plan_pi.md: spinning cores detected by
  the emulator instead, tried and removed).
- GICD_SGIR: software interrupts between cores, and a kernel that
  wakes an idle core with one instead of letting it spin.
- The Pi4 as its firmware starts it: at EL2, `kernel8.img` read from
  the SD card's FAT partition, the other cores parked (section 8).
- USB, well enough for a keyboard.
- An emulated clock that follows the host's time; what breaks.
- Snapshot and restore of the whole machine (registers, RAM, devices).
