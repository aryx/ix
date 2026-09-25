# Plan: mini-qemu, a Raspberry Pi emulator for 9pi and xv6's Pi kernels (`raspberry/`)

Companions: [`notes_pi.md`](../tutorials/notes_pi.md), the tutorial
(the SoC and its buses; ARM's privileged state: modes, banked
registers, exceptions, CP15; the MMU's page tables, ARMv6's and
ARMv7's; the devices a kernel needs; several cores; AArch64's
exception levels, translation tables, GIC and generic timer; the
AArch64-to-AArch32 hand-off), and
[`notes_pi_related_work.md`](../related-work/notes_pi_related_work.md)
(full-system emulation from SimOS and Bochs to QEMU's raspi machines
and TinyEMU; Plan 9 and xv6 on the Pi).

It builds on [`plan_arm.md`](plan_arm.md): mini-5i's CPU cores
(`machine/`: `Arm32`, `Arm64`, `Memory`'s bus), extended with the
privileged state, and devices behind the bus. It is written now, with
plan_arm.md, so that the cores are designed for it; it starts once
mini-5i's phases 1-5 are done.

The author asked for it ("another tiny but for the Raspberry Pi that
rely on the ARM emulator but extended for the qemu-system-part with
MMU, framebuffer, storage"; "emulate after the Pi1 and Pi4"; "study
~/xv6/ and ideally we also want to run the different xv6 Pi kernels
with mini-qemu"; "adjust the plan to support 9pi, 9pi2, but
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
TESTS PASSED" (21 s to 245 s under QEMU). **mini-qemu passes a
port when that test passes on it**, unchanged: mini-qemu takes
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

So mini-qemu has **two personalities, both first-class**: QEMU
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
is compared with mini-qemu's `-hw` console for the same card
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
  against mini-qemu's for the first divergence.
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
  preemption, on every port; passing it unchanged on mini-qemu
  is the acceptance criterion, as QEMU's passing it is the ports'.
- **QEMU for the machine, the ARM manuals for the CPU.** Where QEMU
  departs from hardware, the kernels already work around it (QEMU's
  loader addresses, its stubbed SP804, its mini UART without a
  backend, its DWC2 quirks): mini-qemu behaves as QEMU, noted.
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
raspberry/                 library ix_raspberry; the mini-qemu executable
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

**Amended (2026-09-25): one core first, `-smp`.** The author: "I guess
emulating the 4 cpus would be too slow, so maybe we can take a -cpu
option and for now focus on one cpu handled". The option is QEMU's
own, `-smp N` (QEMU's `-cpu` names the CPU model), default 1, and 1
the only value until the interleaving above is written. QEMU refuses
fewer than 4 cores on raspi4b, so a comparison with QEMU drops the
secondary cores' lines ("hart 1 starting"). A correction too: for an
ELF `-kernel` that is not Linux, QEMU starts **every core at the
ELF's entry** (hw/arm/boot.c's `do_cpu_reset`), not in the spin stub,
which it keeps for Linux; arm64-pi4's `entry.S` parks the others
itself. Later, when speed asks for it: the cores in parallel with
OCaml 5's domains ("in theory we could use ocaml domains to run in
parallel"), a module dune builds only on OCaml 5 (`enabled_if` on
`%{ocaml_version}`: ix builds with 4.14 and 5.1, js_of_ocaml has no
domains), giving up this decision's determinism for that runner only.

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
edge**, as the host is for mini-5i's system calls (`Linux.host`):

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
  links it; the rest of mini-qemu builds without it.
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
  under mini-qemu, and `test-all-graphics`'s checks.
- **C. 9pi.** The mini UART, the mailbox's other tags, EMMC and DMA
  with 9pi's SD image, high-vector and VFP details; 9pi's boot console
  against QEMU's, then its shell.
- **D. The Pi1 as a board.** The `-hw pi1` personality: the SD card's
  boot partition and `config.txt`, the firmware's entry state, the
  devices' silicon behaviours (decision 8), the hub between DWC2 and
  the keyboard; arm-pi1, arm-pi1-bis and 9pi each taking their
  hardware paths; then flashed on the author's Pi1, the serial logs
  compared.
- **G. Pi4, next** (see "Refocus" below). xv6 arm64-pi4 against QEMU
  11.1's raspi4b, one core:
  - **G1. Arm64's privileged state.** Exception levels 0-3, SP_EL0 and
    SP_ELx (SPSel), SPSR/ELR/ESR/FAR/VBAR per level, DAIF, `eret`,
    exceptions taken to EL1 (synchronous: svc, aborts, undefined;
    IRQ), the system registers the kernel reads and writes (SCR_EL3,
    HCR_EL2, SCTLR, TCR, MAIR, TTBR0/1, CurrentEL, MPIDR, the timer's),
    `tlbi`, `dc`, `ic`, barriers, `wfi`, `ldaxr`/`stxr` (spinlocks).
    Addresses become 64-bit (the kernel runs at 0xffffff80_0000_0000):
    the pc a native int (63 bits: canonical addresses fit), a
    register's value translated to a physical address below 4 GB.
  - **G2. Mmu64.** The 4 KB granule, TTBR0/TTBR1 split by TCR's T0SZ and
    T1SZ, levels 0-3, blocks and pages, AP/UXN/PXN, faults' ESR codes;
    a TLB as Mmu32's.
  - **G3. The board.** BCM2711's map (RAM, the PL011 at 0xfe201000,
    GPIO, the GIC-400 at 0xff841000), the generic timer (CNTV, CNTP,
    62.5 MHz, QEMU's cortex-a72), QEMU's loader: the ELF by its
    physical addresses, entered at its entry at EL3; `-M raspi4b`,
    `-cpu cortex-a72`, `-m`, `-smp 1`.
  - **G4. usertests**, then the boot console against QEMU's (less the
    secondary cores' lines); `./mini-pi xv6-pi4`.
  - **G5. `-smp 4`**, interleaved (decision 3); domains as an option.
  The Pi4's framebuffer and USB (xHCI on PCIe) when a kernel drives
  them; `-hw pi4` (EL2 entry, `kernel8.img`) and the author's Pi4
  with phase D.
- **E, F (Pi2, Pi3) and H (virt): dropped**, see "Refocus" below.
- **H'. The web.** The machine compiled by js_of_ocaml with a web
  display (the playground's web backend, or a canvas): a Pi1 with xv6
  in a browser page, the card image fetched; its speed measured.
- **I. `tiny/TinyPi.ml`.**

Each phase checked by the kernels' own tests, by QEMU's trace for the
first divergence when one fails, and, for the boards' personality, by
the boards' serial logs.

## Refocus: the Pi1 and the Pi4 (2026-09-25)

The author: "let's jump to Pi4; we don't want to emulate every arch;
this is a teaching context and a mini- and tiny- so let's focus on pi4
now like for the other programs where we handle both arm32 and
arm64". So mini-qemu has two boards, as the toolchain and mini-5i
have two architectures: the **Pi1** (ARMv6, arm32: 9pi, xv6 arm-pi1
and arm-pi1-bis; phases A-C) and the **Pi4** (AArch64: xv6
arm64-pi4; phase G). The Pi2 and Pi3 (phases E, F: ARMv7's
descriptors, Thumb-2, the AArch64-to-AArch32 hand-off, 9pi2) and
QEMU's `virt` (phase H) are dropped: each is one more kernel for
little new to teach once the Pi1 and Pi4 run. Decision 2's hand-off
goes with them: a core runs one instruction set.

## Outside QEMU: TinyPi.ml

Free, in one file: the smallest machine a kernel can run on -- an ARM
core subset, RAM, a UART, a timer and an interrupt line, sections-only
MMU -- and a kernel of a page for it, printing and taking timer
interrupts: the machine a first operating-systems course would want
(TinyEMU's spirit, in OCaml). Checked by its laws: the kernel's
output, the interrupts' count per simulated second.

TinyPi is TinyArm.ml's machine, as TinyMachine.ml (plan_arm.md) is
TinyCPU.ml's (2026-09-25): the tiny emulators are two by two, an
instruction set inherited (ARM) or designed (TinyCPU's), a CPU seen
from user mode or a machine with devices:

                   CPU, user mode     machine, devices
    inherited      TinyArm.ml         TinyPi.ml
    designed       TinyCPU.ml         TinyMachine.ml

The CPUs' world ends at a system call, which the interpreter answers
itself; the machines' subject is below it, what a kernel sees: the
processor's modes, the exception vector, an interrupt arriving
between two instructions, the MMU, the devices behind addresses.
TinyPi's are inherited too: its core is TinyArm's arm32, the Pi1's,
with the modes, CP15 and the exceptions added, and its devices are
the Pi1's own registers (a subset: a UART, the system timer, the
interrupt controller), so that a bare-metal program for the Pi1 (the
"Baking Pi" kind) runs on it and on the real board.

Each machine relies on its CPU, not a copy of it: TinyArm.ml's
instructions, assembler and interpreter are a library,
tiny/TinyLibArm.ml (the tiny/TinyLibXxx.ml convention for code tiny
files share), TinyArm.ml keeping its command line, its three system
calls and the ELF writer; TinyPi.ml is the modes, the exceptions and
the devices around it. The library's `step` takes an `env` of four
hooks, what a machine changes: the load and the store (devices behind
addresses), what svc does (a system call answered, or an exception
taken: the hook sees r15 as the return address and may change it),
and what a word `decode` does not know does (the privileged
instructions: mrs, msr, cps, the coprocessor's, which the subset
leaves out); the check between two instructions (an interrupt
pending) is in the machine's loop around `step`. The state the CPU
record lacks (the mode, the banked registers, the saved status) is
TinyPi's, beside it. TinyMachine.ml and tiny/TinyLibCPU.ml the same
way (plan_arm.md).

**Split done** (2026-09-25): `tiny/TinyLibArm.ml` (720 lines) and
`tiny/TinyArm.ml` (100 lines: Linux's three calls, the process's
stack, the ELF, the command line); TinyArm_test.sh unchanged and
passing (GNU as's bytes, objdump's listing, the runs on the CPU and
under mini-5i, 3,000 random instructions).

## Verification

`make test-pi`: each xv6 port's `test-xv6.py` with mini-qemu as
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
required). Starts after mini-5i's phases 1-5.

**Phase A, first port done** (2026-09-25): **xv6 arm-pi1-bis passes its
own acceptance test under mini-qemu**: `test-xv6.py`, unchanged,
run with `QEMU=mini-qemu`, boots, runs `usertests`, "ALL TESTS PASSED",
in 2 min 9 s (QEMU 8.2: 22 s; the harness allows 300). The boot's
console, to the shell's prompt, is byte for byte QEMU's
(`raspberry/tests/xv6.sh`); the aborts usertests provokes print the
same addresses and status registers as under QEMU.

What it took (a survey of the port first, 2026-09-25: its boot path,
its CP15 operations, the devices and the values that keep it from
hanging, read against QEMU 11.1's sources):

- machine/'s `Arm32` with the privileged state (modes and banks, the
  SPSRs, exceptions, `movs pc` and `ldm ^` returns, `ldm`/`stm ^` on the
  user registers, `mrs`/`msr` on the SPSR, `mcr`/`mrc`/`mcrr`, the
  hints), ARMv6's extends (`uxtb`, `sxtah`...), loads and stores
  through an MMU hook leaving the registers unchanged on an abort; a
  mode the CPU lacks ignored, as QEMU's Non-secure Pi (xv6's tvinit
  writes monitor mode and counts on it staying SVC);
- `Mmu32`: ARMv6's short descriptors, the legacy subpage format this
  kernel uses and the ARMv6 one, domains, the FSR's codes, a TLB;
- `raspberry/`: `Board` (CP15, 512MB, QEMU's loader, the loop: a decode
  cache by virtual address and privilege flushed with the TLB, aborts
  and undefined instructions as exceptions, the system timer's
  microsecond every 30 instructions), `Intc`, `Systimer`, `Pl011`,
  `Devices` (AUX, GPIO, the mailbox's property tags and framebuffer
  channel as QEMU answers them, the DWC2 with QEMU's reset values and
  id, so that CSUD enumerates its root hub as under QEMU); `mini-qemu`
  taking QEMU's command line.

**Phase A done** (2026-09-25): **xv6 arm-pi1 passes too**, its
`test-xv6.py` unchanged with `QEMU=mini-qemu` (its `kernel-qemu.img`):
"ALL TESTS PASSED" in 2 min 42 s, its boot byte for byte QEMU's; it
needed nothing arm-pi1-bis had not. Its hard-float build has no VFP
instruction in the kernel or the programs (the census said so,
`census_xv6.txt`): VFP moves to phase C, for 9pi's programs.
`raspberry/tests/xv6.sh` checks both boots against QEMU (`-u`: and
both usertests).

**Phase B done** (2026-09-25): the Pi1's graphics and USB keyboard.
xv6's own graphical test (`scripts/test_qemu_graphics.py`: a
screen with pixels, more after typing "ls" by QMP, the command on the
serial console), unchanged with `MAKEFLAGS=QEMU_ARM=mini-qemu`, **passes
for arm-pi1-bis and arm-pi1**; and headless
(`raspberry/tests/graphics.py`) both ports' serial output (the USB
devices enumerated, the typed command, its listing) and QMP
screendumps before and after typing are **byte for byte QEMU's**.

- `Usb`: QEMU's usb-kbd and the hub QEMU puts on a one-port controller
  when a device is attached (its descriptors, strings, serial numbers
  with their port paths, the hub's port status and features), with
  QEMU's control-transfer state machine: an OUT request runs at its
  status stage, so SET_ADDRESS completes at the address it had (running
  it at SETUP, as first written, left the status stage without a
  device: CSUD's "Request to USB 1.1 Hub has timed out").
- `Dwc2`: QEMU's host channels (a transfer whole at enable, HCTSIZ and
  HCINT as QEMU leaves them, no ACK) and root port (a reset enables it).
- `Framebuffer` (channel 1's geometry, RGB565 shifted up as QEMU's
  display: white is f8 fc f8), `Display` (the record), `Sdl_display`
  (tsdl: the framebuffer as an RGB565 texture, drawn when it changed --
  converting 786,432 pixels to RGB in OCaml each frame took 16 ms and
  starved the CPU: the window's first boot missed the test's 60 s),
  `Qmp` (a Unix socket: qmp_capabilities, query-status, screendump,
  send-key held 100ms of the board's time, quit).

**Phase C done** (2026-09-25): **principia's 9pi boots under
mini-qemu as under QEMU**: run as principia's `mkfile-target-pi`
runs it (`-device loader` at 0x8000, the SD card image, `-serial null
-serial mon:stdio`: the mini UART the console), it reaches rc's prompt
and a session of commands (`raspberry/tests/9pi.py`: ls, cat, wc, a
pipe, the card's control file, a file written to the card and read
back, a floating point program) prints **byte for byte QEMU's
console**, the program's death included (5c's code is FPA, which 9pi
does not emulate: "hoc 48: suicide: undefined instruction: pc 0x3ba4"
on both). A survey first (2026-09-25; principia's own notes,
`docs/claude_notes/qemu_raspi1ap.txt`, had the QEMU bring-up written).

- machine/'s `Arm32`: `swp`, `ldrex`/`strex`/`clrex` (a monitor), the
  barriers, and VFP's part the kernel uses (`vmrs`/`vmsr` of FPSID,
  FPSCR, FPEXC; `vldr`/`vstr` of the double registers), granted by
  CPACR, FPEXC.EN required but for the control registers (the lazy
  switch's trap).
- `raspberry/`: `Miniuart` (QEMU's AUX), `Sdhost` (the Arasan
  controller and QEMU's SD card: its CID, a standard capacity CSD, OCR
  80ffff00, RCA 4567, version word 0x2402), `Dma` (control blocks run
  at once, IRQ 16 + channel), FIQ in `Intc` (USB's, line 9), the
  DWC2's interrupt line, the mailbox's framebuffer configuration and
  other tags (clocks by id, temperature, resolution and depth: QEMU's
  640x480x16), CP15's feature registers, CCNT 0, CPACR as QEMU keeps
  it (0xC0F00000), WFI: the time jumps to the next timer compare;
  `Storage` (the card's image, in place or snapshot=on); the command
  line's `-device loader`, `-bios`, `-drive`, and QEMU's serial order.

The ARM timer (0xB400) stays unassigned as in QEMU's raspi1ap (reads 0,
no interrupt), so 9pi's USB driver wakes on its 1s timeouts there too.

**Phase D deferred** (2026-09-25), at the author's request: the real
Pi1 board personality (`-hw pi1`, the boot partition, the firmware's
entry state, the flashed board) waits; the next phases do not depend
on it.

**Phase G, G1-G3 done; G4 under way** (2026-09-25): **xv6 arm64-pi4
boots under mini-qemu on one core**, its console to the shell's prompt
the same as QEMU 11.1's raspi4b (less its other cores' "hart N
starting"; `raspberry/tests/xv6.sh arm64-pi4`), and `ls` and the
programs run. usertests' faults are reported as QEMU reports them
(MAXVAplus's 64: the same ESR, with the fault's level, FAR and ELR).

- machine/'s `Arm64`: the exception levels (SPSel and the stack
  pointers per level, DAIF, ELR/SPSR/ESR/FAR/VBAR per level, `eret`,
  exceptions to EL1 with the vector's four origins), the system
  registers by a table of those the kernels use (objdump's names; the
  rest undefined, so random words stay checkable), the hints, barriers,
  `dc`/`ic`/`tlbi`/`at`, `hvc`/`smc`/`brk`, the exclusive and ordered
  loads and stores with a monitor; 64-bit program counters (a native
  int holds the canonical 0xffffff80... addresses; js_of_ocaml keeps
  its 32 bits); accesses through the MMU at EL0-1. User mode unchanged
  (mini-5i: the same tests, 29.6 MIPS).
- machine/'s `Mmu64`: the 4 KB granule, TTBR0/TTBR1 by T0SZ/T1SZ,
  levels 0-3, blocks and pages, AP/UXN/PXN, the access flag, the fault
  codes with their level; a TLB as Mmu32's.
- `raspberry/`: `Gic` (the GIC-400, one core's view), `Pi4` (the board:
  RAM from 0, the PL011 at 0xfe201000 on SPI 153, GPIO, the GIC, the
  generic timer's CNTV and CNTP at 62.5 MHz on PPIs 27 and 30, QEMU's
  ELF loading at EL3), `Main`: `-M raspi4b`, `-m`, `-smp 1`, `-cpu`,
  `-trace N`; `./mini-pi xv6-pi4`.
- Tests: `machine/tests/words_arm64_system.txt` (3,850 words: xv6
  arm64-pi4's kernel and programs, and `system_arm64.s`, from
  `census_system.sh`) against objdump.

Speed: 27 MIPS, the user-mode interpreter's. xv6's boot takes 21s
(kinit fills 128MB a byte at a time, 670M instructions: QEMU 0.1s);
usertests, 183s under QEMU's four threaded cores, is dominated by the
same byte loop (`memset`, 58% of MAXVAplus's samples: three a page
allocated and freed) and takes far longer than the harness's 300s.

**G4's tests, fast** (2026-09-25). The author: "let's keep that simple
design for now; simplicity is the most important thing as this is a
teaching project; we can optimize if the optimization keep the simple
code path clear [...] Then for sure we want a fast test infra, so I
would reduce the tests for the pi ... maybe lowering some test
constants". The constant is xv6's PHYSTOP: both the boot (kinit) and
every usertests run (countfree, before and after its tests, even for
one) touch each page of it with byte loops, 21s and 70s at 128MB. So
`raspberry/tests/xv6_pi4.py` builds a copy of the kernel with 4MB (in
a mirror of ~/xv6, which stays untouched) and runs its boot and 16 of
usertests' tests one by one (`usertests NAME`, about 4s each) under
QEMU and mini-qemu in parallel, each test's output byte for byte the
same: 75s, in `make test-pi`. Measured per test on 4MB: 52 of the 62
pass in under a minute here with QEMU's output (`-a` runs them); left
out sbrkmuch (100MB) and eight that loop over forks or execs (2-18s
under QEMU, minutes here). The pids are QEMU's when the sequence is
the same, one core or four.

**G4 done** (2026-09-25): **xv6 arm64-pi4 passes its usertests under
mini-qemu**, the real kernel (128MB), one core: all 62 tests, ALL
TESTS PASSED in 3,023s (50 minutes; QEMU's four threaded cores: 183s),
run by the port's own harness function (`test_usertests`) with a
3-hour limit instead of its 300s.
