# Plan: TinyRaspberryPi, a Raspberry Pi emulator for 9pi and xv6's Pi kernels (`raspberry/`)

Companions: [`notes_pi.md`](../tutorials/notes_pi.md), the tutorial
(the SoC and its buses; ARM's privileged state: modes, banked
registers, exceptions, CP15; the MMU's page tables, ARMv6's and
ARMv7's; the devices a kernel needs; several cores; AArch64's
exception levels, translation tables, GIC and generic timer; the
AArch64-to-AArch32 hand-off), and
[`notes_pi_related_work.md`](../related-work/notes_pi_related_work.md)
(full-system emulation from SimOS and Bochs to QEMU's raspi machines
and TinyEMU; Plan 9 and xv6 on the Pi).

It builds on [`plan_arm.md`](plan_arm.md): TinyArm's CPU cores
(`machine/`: `Arm32`, `Arm64`, `Memory`'s bus), extended with the
privileged state, and devices behind the bus. It is written now, with
plan_arm.md, so that the cores are designed for it; it starts once
TinyArm's phases 1-5 are done.

The author asked for it ("another tiny but for the Raspberry Pi that
rely on the ARM emulator but extended for the qemu-system-part with
MMU, framebuffer, storage"; "emulate after the Pi1 and Pi4"; "study
~/xv6/ and ideally we also want to run the different xv6 Pi kernels
with TinyRaspberryPi"; "adjust the plan to support 9pi, 9pi2, but
also possibly the Pi1 and Pi4 (and maybe more) under ~/xv6/"; "ultimately
I want to boot on a real pi1, pi2, and pi4 (that I own). in xv6 there
also some graphics-run target that requires usb and framebuffer and so
on, which are also required by the physical pi to work correctly").

## The kernels it must boot

Eight kernels, from two families, surveyed (principia's `kernel/`,
and xv6-multiarch's `forks/`, with each port's
`docs/claude_notes/notes_arch_*.txt`):

| kernel | ISA, CPU | board (QEMU) | cores | console | tick | storage | other devices |
|---|---|---|---|---|---|---|---|
| **9pi** (principia, `conf/arm/pi`) | ARMv6, ARM1176, VFP | raspi1ap | 1 | mini UART | system timer C3 | EMMC + DMA (SD image) | mailbox (property tags), framebuffer, watchdog, USB (DWC2) |
| **9pi2** (`conf/arm/pi2`) | ARMv7, Cortex-A7 | raspi2b | 4 | mini UART | generic timer | EMMC + DMA | ARM-local interrupts and mailboxes |
| **xv6 arm-pi1** | ARMv6, ARM1176, hard-float | raspi1ap | 1 | PL011 (+ mini UART) | system timer C3, 100 Hz | ramdisk in the kernel | mailbox ch8 + ch1 framebuffer, USB keyboard (csud) |
| **xv6 arm-pi1-bis** | ARMv6, soft-float | raspi1ap | 1 | PL011 (+ mini UART) | system timer C3 | ramdisk | mailbox, framebuffer, USB (csud) |
| **xv6 arm** | ARMv7-A, soft-float, -O0 | raspi2b | 1 (others parked) | PL011 | system timer C3, 100 Hz | ramdisk | -- |
| **xv6 arm-pi2** | ARMv7, Cortex-A7, hard-float, NEON | raspi2b | 1 | PL011 (+ mini UART) | system timer C3 | ramdisk | mailbox, framebuffer |
| **xv6 arm-pi3** | AArch32 on a Cortex-A53, after an AArch64 stub at EL2 | raspi3b | **4**, `ldrex/strex` | PL011 | system timer C3, 20 Hz | ramdisk | mailbox, framebuffer, USB (uspi) |
| **xv6 arm64-pi4** | AArch64, Cortex-A72, no FP | raspi4b | **4**, spin table | PL011 | generic timer (CNTV, PPI 27) | ramdisk | **GIC-400** |

and one optional more, "maybe more": **xv6 arm64** on QEMU's `virt`
machine (GICv3, PL011 at 0x09000000, virtio-blk, PSCI to start cores):
not a Pi, but the standard AArch64 board, and the cheapest way to
virtio.

Each xv6 port has its own acceptance test, run by its
`test-xv6.py`: boot, a shell prompt, `ls`, then `usertests` to "ALL
TESTS PASSED" (21 s to 245 s under QEMU). **TinyRaspberryPi passes a
port when that test passes on it**, unchanged: TinyRaspberryPi takes
the part of QEMU's command line these ports use (`-M raspi1ap|raspi2b|
raspi3b|raspi4b`, `-kernel` raw or ELF, `-device loader,file=,addr=,
force-raw=on`, `-m`, `-smp`, `-nographic`, `-serial mon:stdio`), so the
ports' Makefiles and harnesses run it as they run QEMU.

## Toward the real boards

The author owns a **Pi1, a Pi2 and a Pi4**, and the kernels are meant to
boot on them: 9pi and xv6 arm-pi1 and arm-pi1-bis on the Pi1; 9pi2 and
xv6 arm and arm-pi2 on the Pi2; xv6 arm64-pi4 on the Pi4 (arm-pi3 stays
QEMU-only: no Pi3). None of xv6's has been booted on a board yet
(xv6-multiarch's `plan_build_and_test_2.md`, §3: "the single largest
untested claim in the repo"), and they cannot be exercised under
QEMU: each kernel **detects QEMU and takes another path** -- 9pi's and
xv6's `emulating()` read the DWC2 USB controller's id (QEMU's 2.94a
against the silicon's 2.80a) and then skip the power handshake on the
mailbox's channel 0, USB split transactions, the watchdog; xv6
arm64-pi4 enters at EL3 under QEMU and EL2 on the board; QEMU's mailbox
answers a framebuffer's *physical* address where the firmware answers a
bus address; its mini UART has no backend; its SP804 timer is a stub.
The real-hardware paths are the ones never run.

So TinyRaspberryPi has **two personalities, both first-class**: QEMU
is the convenient machine -- fast to run, scripted, the one every
port's tests already use, the everyday path and `make test`'s -- and the
boards are the ones that matter in the end; neither replaces the
other:

- **`-M raspi1ap` ... (QEMU's, the default)**: QEMU's loader, QEMU's
  device behaviour, its quirks included -- for the differential tests
  against QEMU, to run xv6's harnesses unchanged, and for everyday use;
- **`-hw pi1|pi2|pi4` (the board's)**: the firmware's boot and the
  silicon's behaviour -- the SD card's boot partition read as the
  firmware reads it (`config.txt`, `kernel.img`, `kernel7.img`,
  `kernel8.img`, loaded at 0x8000 or 0x80000, the core in the state the
  firmware leaves it: SVC on the Pi1, HYP on the Pi2, EL2 on the Pi4,
  with ATAGs or a device tree's address in r2 or x0), and the devices as
  the datasheets describe them (the DWC2's real id, the channel-0
  handshake answered, bus addresses from the mailbox, a working mini
  UART and SP804, the Pi1's and Pi2's LAN9512/9514 hub between the
  controller and the keyboard). The kernels then take the paths the
  boards will make them take: **the image to flash is the image
  emulated.**

The references for the second personality are the documents (BCM2835
ARM Peripherals, the BCM2711 datasheet, the firmware's boot and
mailbox documentation; from memory, to check) and the kernels' own
real-hardware code; and, finally, **the boards themselves**: each
board's serial console, captured (a USB-to-serial cable on GPIO 14/15),
is compared with TinyRaspberryPi's `-hw` console for the same card
image -- the last differential, and the one xv6-multiarch's plan asks
for ("flash, boot, capture the serial log").

**Graphics and USB are then required, not optional.** xv6's graphical
targets (`run-arm-pi1-qemu-graphics`, `arm-pi1-bis`, `arm-pi3`: a
framebuffer console and a USB keyboard; `make test-all-graphics`) and a
board's normal use need the framebuffer (the mailbox's channel 1, and
the property interface's framebuffer tags, the only way on the Pi4) and
USB: the DWC2 host controller and a keyboard behind it (on the boards,
behind the hub; on the Pi4, whose USB-A ports are an xHCI controller on
PCIe (the VL805, from memory), a separate and larger model, planned
last, and only once a kernel drives it -- xv6 arm64-pi4 has neither
framebuffer nor USB yet).

## Context

A Raspberry Pi is a system on a chip: ARM cores, RAM, and devices at
fixed physical addresses (0x20000000 on the Pi1's BCM2835, 0x3F000000
on the Pi2's and Pi3's, 0xFE000000 on the Pi4's BCM2711; the
documents' "bus" address 0x7E000000 in all). A system emulator runs
the machine from the state the firmware (here: QEMU's loader) leaves
it in; everything else is the guest's.

- **The references are QEMU's raspi machines**, which boot all eight:
  QEMU 8.2 (`/usr/bin`) for raspi1ap, raspi2b, raspi3b; a local QEMU
  11.1 build (`/home/pad/work/TOOLCHAINS/qemu/build`) for raspi4b.
  Console output compared; QEMU's instruction trace (`-d in_asm,cpu`)
  against TinyRaspberryPi's for the first divergence.
- **The kernels decide the instruction set, measured**
  (`machine/tests/xv6_census.sh`, `census_xv6.txt`): the xv6 ports'
  kernels and user programs, disassembled with their mapping symbols,
  use **84 to 108 ARM mnemonics** each, **Thumb only in libgcc's
  division routines** (35 Thumb-2 mnemonics, in `arm`'s build), **six
  VFP/NEON instructions** (`vst1.32 vmov.i32 vldr vpush vpop vmsr`:
  gcc's vectorized stores, in arm-pi2 and arm-pi3); arm64-pi4 runs 80
  AArch64 mnemonics booting, with no floating point. 9pi adds VFP for
  user programs' floating point.
- **The kernels decide the devices**: seven device models cover all
  eight kernels (decision 4's table).

## Principles

Those of [`../README.md`](../README.md), and:

- **The kernels' tests are the tests.** xv6's `usertests` exercises
  fork, exec, pipes, the file system, memory allocation, page faults,
  preemption, on every port; passing it unchanged on TinyRaspberryPi
  is the acceptance criterion, as QEMU's passing it is the ports'.
- **QEMU for the machine, the ARM manuals for the CPU.** Where QEMU
  departs from hardware, the kernels already work around it (QEMU's
  loader addresses, its stubbed SP804, its mini UART without a
  backend, its DWC2 quirks): TinyRaspberryPi behaves as QEMU, noted.
- **Devices are small state machines behind the bus**: an address
  range, a load and a store, an optional tick, interrupt lines. No
  device knows the CPU.

## Target layout

```
machine/ (extended)
  Arm32.ml, Arm64.ml       + privileged state (modes, banked registers,
                           SPSR; exception levels), exceptions, system
                           instructions (MRS/MSR/CPS/RFE/SRS/ERET,
                           MCR/MRC/MCRR, system registers), LDREX/STREX,
                           LDAXR/STLXR, barriers
  Thumb.ml(i)              the Thumb-2 subset libgcc's division runs
  Vfp.ml(i)                VFPv2/v3 for 9pi's programs and gcc's few
                           NEON stores
  Mmu32.ml(i)              short descriptors, ARMv6 legacy (XP=0) and
                           ARMv7 (XP=1, TTBR0/TTBR1 split by TTBCR.N)
  Mmu64.ml(i)              4 KB granule, 39- and 48-bit VAs, ASIDs
raspberry/                 library ix_raspberry; the tinypi executable
  Board.ml(i)              the boards: RAM, the bus's map, the cores,
                           QEMU's loader conventions
  Smp.ml(i)                cores interleaved, the exclusive monitor
  Intc.ml(i)               BCM2835 interrupt controller
  Local.ml(i)              BCM2836 ARM-local: timers, mailboxes (9pi2)
  Gic.ml(i)                GIC-400 (Pi4); GICv3 (virt, optional)
  Systimer.ml(i)           the system timer; the generic timer
  Uart.ml(i)               PL011; mini UART (AUX) and GPIO
  Mailbox.ml(i)            property tags; legacy channel 1 framebuffer
  Emmc.ml(i), Dma.ml(i)    the SD card, for 9pi
  Dwc2.ml(i), Usbkbd.ml(i) USB: the DWC2 host controller, a hub (the
                           boards' LAN951x), a HID keyboard
  Framebuffer.ml(i)        the framebuffer's device side: its RAM,
                           its geometry, the refresh; shown through a
                           display record (decision 9)
  Sdl_display.ml(i)        the display in an SDL window (tsdl), the one
                           module linking a C library
  Ppm_display.ml(i)        headless: PPM snapshots, for the tests
  Firmware.ml(i)           the board's boot: the SD card's FAT boot
                           partition, config.txt, the kernel's load
                           address and entry state, ATAGs or a DTB
  CLI.ml(i), Main.ml       QEMU's command line, the subset; -hw
tiny/TinyPi.ml             the free variant
```

**The size target**: the core extensions 1,700 (Arm32 privileged 350,
Arm64 privileged 400, Thumb 200, Vfp 300, Mmu32 250, Mmu64 200),
Board+Smp 350, the devices 1,300 (Intc 120, Local 120, Gic 250,
Systimer 150, Uart 200, Mailbox 200, Emmc+Dma 400),
CLI 150; for the boards, Firmware (a FAT reader, config.txt) 300,
Framebuffer 150, Dwc2 + Usbkbd + hub 700: **about 4,700 lines**.

## Groundwork decisions

### 1. Privileged state inside the same variants

The CPSR becomes the architecture's (N Z C V, the I, F, A masks, the
mode); r13 and r14 banked per mode (r8-r12 too for FIQ), swapped at a
mode change so the common path costs nothing. An exception: SPSR, LR,
mode, masks, the vector (low, high at 0xffff0000, or VBAR on ARMv7).
On AArch64: SPSR_ELn, ELR_ELn, ESR_ELn, the vector table at
VBAR_ELn.

### 2. One core, two instruction sets

arm-pi3's first instructions are AArch64 (QEMU's ROM takes the core
from EL3 to EL2, xv6's `armstub64` sets `HCR_EL2.RW = 0` and `eret`s
to AArch32 SVC at 0x90000). So a core is a state that either decoder
can run: the AArch32 registers are the low halves of x0-x14 (the
architecture's own mapping), and an exception return to a lower level
with AArch32 in its SPSR switches the decoder. arm-pi1 to arm-pi2 run
only AArch32; arm64-pi4 only AArch64.

### 3. Several cores, one thread, deterministic

arm-pi3 and arm64-pi4 run four cores; 9pi2 too. The cores run in turn,
a quantum of instructions each (1,000, adjustable), in one OCaml
thread: runs are repeatable (principle 6), and a race shows up the
same way each time. Exclusive loads and stores keep a monitor per
core, cleared by any other core's store to the address (and by a
quantum switch, conservatively: `strex` then fails and retries, as it
may on hardware). Barriers (`dmb`, `dsb`, `isb`) are no-ops; `wfe` and
`wfi` end the core's quantum, `sev` wakes the others. Secondary cores
start parked where QEMU parks them (raspi2b: its spin stub; raspi3b
and raspi4b: polling the spin table at 0xe0, 0xe8, 0xf0).

### 4. Devices by the kernels' use

| device | used by | registers that matter |
|---|---|---|
| BCM2835 interrupt controller (base +0xB200) | all 32-bit kernels | pending (basic, 1, 2), enable, disable |
| system timer (+0x3000) | all 32-bit kernels | CS, CLO, CHI, C3 (compare 3 = interrupt 3) |
| PL011 UART0 (+0x201000) | all xv6 ports | DR, FR, IBRD, FBRD, LCRH, CR, IMSC, ICR, MIS; interrupt 57 (SPI 153 on the Pi4) |
| mini UART, AUX, GPIO (+0x215000, +0x200000) | 9pi, 9pi2 (xv6 writes it too) | AUX_MU_IO, LSR, enables; GPFSEL, GPPUD |
| mailbox (+0xB880) | 9pi, xv6 arm-pi1, arm-pi2, arm-pi3 | read, status, write; channel 8 property tags, channel 1 framebuffer |
| EMMC and DMA (+0x300000, +0x7000) | 9pi, 9pi2 | SD commands, block transfer by DMA channel 4 |
| GIC-400 (0xff841000, 0xff842000) | xv6 arm64-pi4 | distributor, CPU interface, banked PPIs |
| generic timer (system registers) | arm64-pi4, 9pi2 | CNTV_CTL, CNTV_TVAL, CNTFRQ |
| ARM-local (0x40000000) | 9pi2 | local timers, per-core mailboxes |

Registers outside these are logged and read as zero. The SP804 ARM
timer, stubbed by QEMU, is modelled only in the boards' personality (it works on
silicon). USB (DWC2, a hub, a keyboard) and the framebuffer are the
graphical consoles' and the boards': required (see "Toward the real
boards").

### 5. The MMU as a bus in front of the bus

A TLB (by page) in front of the walk: ARMv6 short descriptors in both
their forms (arm-pi1 sets no XP bit: the legacy subpage format; 9pi
and the ARMv7 ports set it), TTBCR's split between TTBR0 and TTBR1
(xv6 arm: N = 4), domains, faults with FSR/FAR (DFSR/DFAR, IFAR);
AArch64's 4 KB granule with 39-bit VAs (arm64-pi4: T0SZ = T1SZ = 25,
three levels, 2 MB blocks) and ASIDs. The decode cache is keyed by
physical address, flushed by I-cache invalidations; cache operations
(by set/way, by MVA, all) are otherwise no-ops.

### 6. Time: counted instructions

Timers advance by instructions executed (a nominal rate), so runs are
deterministic; QEMU's own quirks the kernels guard against (its system
timer skipping values) need no imitating. An option follows the host's
clock, for interactive use.

### 7. Loading as QEMU loads

`-kernel` with a raw image: at 0x10000 on raspi1ap and raspi2b, at
0x80000 on raspi3b and raspi4b; an ELF: at its segments' addresses.
`-device loader,file=,addr=,force-raw=on`: at the address. The entry
state is QEMU's (raspi1ap and raspi2b: SVC mode; raspi3b: EL2 after
QEMU's ROM; raspi4b: EL3, which xv6's entry takes down to EL2 and
EL1), with r0-r2 or x0 as QEMU sets them, and the board's firmware
conventions (the spin table) in RAM.

### 8. Two personalities, one machine

QEMU's and the board's differ in the loader and in a list of device
behaviours, each a flag of the device model, set by the personality:
the DWC2's id, the mailbox's channel 0 and its framebuffer addresses,
the mini UART's backend, the SP804, the watchdog, the entry state. The
list is the kernels' own `emulating()` branches and QEMU workarounds
(xv6's `notes_arch_*.txt`, 9pi's `usbdwc.c`), each a test: a kernel
under `-hw` must take its hardware branch.

### 9. The framebuffer through a display record, SDL first; the keyboard back through USB

The screen and the input devices are **a record of functions at the
edge**, as the host is for TinyArm's system calls (`Linux.host`):

```ocaml
type display = {
  present : Bytes.t -> width:int -> height:int -> unit;  (* the framebuffer, at each vsync *)
  poll : unit -> event list;                             (* keys, mouse: USB HID reports *)
}
```

The window shows the framebuffer's RAM at each vertical refresh (60
times a simulated second); a key pressed in it becomes a USB HID
report the emulated keyboard delivers when the kernel's driver polls.
Two backends first:

- **SDL, through tsdl** (the opam package, 1.3.0 installed here): a
  window, a streaming texture updated from the raw pixels, the
  keyboard and mouse events. `Sdl_display` is the one module that
  links it; the rest of TinyRaspberryPi builds without it.
- **PPM, headless** (the tests): the framebuffer written on request,
  the graphical tests comparing pictures (the console's text drawn in
  pixels).

The author's playground libraries (`~/playground`: the Elm
playground's OCaml port, its Cairo, SDL and web backends) were the
first choice; tsdl was preferred for now (the author: "maybe it's ok
to rely on tsdl directly rather than the playground. we can always
migrate to the playground later"): a standard package, a raw-pixel
texture with no question of which API draws an image, and no coupling
to another repository's moving interface. A playground backend is a
third implementation of the same record, when wanted.

**The web** stays a target, postponed rather than dropped: tsdl has
C stubs, so the browser build needs another display (the playground's
web backend, or a canvas through js_of_ocaml's DOM bindings; phase
H'). What makes it possible is kept from the first line of
`machine/`: the cores and devices use no C stubs and nothing of
`Unix` (the host -- files, console, window, clock -- stays behind
records of functions at the edge), and the arithmetic that depends on
OCaml's integer width (63 bits native, 32 under js_of_ocaml, `Int64`
emulated and slow there) is in `Bits` alone (plan_arm.md, decision 3).

## Phases

- **A. Pi1, xv6 first.** arm-pi1-bis then arm-pi1: Arm32's privileged
  state, Mmu32 (legacy descriptors), the interrupt controller, the
  system timer, the PL011, the mailbox's memory tag; boot, then
  `usertests`. Then VFP (arm-pi1's hard-float).
- **B. The Pi1's graphics and USB.** The framebuffer (channel 1) in a
  window, DWC2 and a keyboard: `run-arm-pi1-qemu-graphics`'s session
  under TinyRaspberryPi, and `test-all-graphics`'s checks.
- **C. 9pi.** The mini UART, the mailbox's other tags, EMMC and DMA
  with 9pi's SD image, high-vector and VFP details; 9pi's boot console
  against QEMU's, then its shell.
- **D. The Pi1 as a board.** The `-hw pi1` personality: the SD card's
  boot partition and `config.txt`, the firmware's entry state, the
  devices' silicon behaviours (decision 8), the hub between DWC2 and
  the keyboard; arm-pi1, arm-pi1-bis and 9pi each taking their
  hardware paths; then flashed on the author's Pi1, the serial logs
  compared.
- **E. Pi2.** xv6 arm (ARMv7 descriptors, TTBR split, the Thumb-2
  subset), arm-pi2 (VBAR, CPACR/FPEXC, the NEON stores); 9pi2 (the
  ARM-local block, the generic timer, four cores); then `-hw pi2`
  (HYP-mode entry) and the author's Pi2.
- **F. arm-pi3.** Four cores (decision 3), the AArch64 stub at EL2 and
  the switch to AArch32 (decision 2), `ldrex/strex`, its graphics
  target (uspi's USB).
- **G. Pi4.** xv6 arm64-pi4: Arm64's exception levels and system
  registers, Mmu64, the GIC-400, the generic timer, four cores; against
  QEMU 11.1's raspi4b; then `-hw pi4` (EL2 entry, `kernel8.img`) and the
  author's Pi4. The Pi4's framebuffer (property tags) and USB (xHCI on
  PCIe) when a kernel drives them.
- **H. Optional: virt.** xv6 arm64 on `virt`: GICv3, PSCI, virtio-blk.
- **H'. The web.** The machine compiled by js_of_ocaml with a web
  display (the playground's web backend, or a canvas): a Pi1 with xv6
  in a browser page, the card image fetched; its speed measured.
- **I. `tiny/TinyPi.ml`.**

Each phase checked by the kernels' own tests, by QEMU's trace for the
first divergence when one fails, and, for the boards' personality, by
the boards' serial logs.

## Outside QEMU: TinyPi.ml

Free, in one file: the smallest machine a kernel can run on -- an ARM
core subset, RAM, a UART, a timer and an interrupt line, sections-only
MMU -- and a kernel of a page for it, printing and taking timer
interrupts: the machine a first operating-systems course would want
(TinyEMU's spirit, in OCaml). Checked by its laws: the kernel's
output, the interrupts' count per simulated second.

## Verification

`make test-pi`: each xv6 port's `test-xv6.py` with TinyRaspberryPi as
its QEMU, boot then `usertests`; 9pi's boot console against QEMU's;
the graphical targets' pictures; under `-hw`, each kernel's hardware
branches taken, and the boards' captured serial logs (kept in the
repository with the card image's hash) matched.
Needs `~/xv6` built and, for the Pi4, QEMU 11.1's raspi4b only to
compare, not to test.

## Status

2026-09-24: plan written with plan_arm.md; revised for xv6's six Pi
ports and 9pi2 the same day, from the survey and the census
(`machine/tests/xv6_census.sh`); revised again for the author's real
Pi1, Pi2 and Pi4 (the boards' personality, graphics and USB
required). Starts after TinyArm's phases 1-5.
