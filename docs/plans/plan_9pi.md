# Plan: mini-9pi, principia's Plan 9 kernel in OCaml on the Pi1 (`kernel/9pi/`)

The author (2026-09-26): "let's start mini-9pi? We probably want a plan
to this one? and to address graphics and networking this time?"

mini-9pi is the twin of principia's **9pi**, the Plan 9 kernel for the
Raspberry Pi 1 that principia's books explain (`~/principia/kernel`,
`Kernel.nw`), as mini-xv6 ([`plan_kernel.md`](plan_kernel.md)) is xv6
arm-pi1's: written in OCaml with ocaml-light, running **principia's own
user programs from its own SD card image** (`~/principia/qemu-sd.img`),
compared with the C kernel under QEMU and mini-qemu -- the console's
bytes, then the screen's pixels. Its milestones: rc's prompt, then
rio, then a TCP connection.

## The survey (2026-09-26, `~/principia`, checked)

What 9pi is (`kernel/conf/arm/pi`, built in `kernel/COMPILE/9/bcm`, a
1.8MB image loaded at 0x8000), by lines of compiled C and assembly:

| part | lines | what |
| --- | ---: | --- |
| portable core | 18,841 | processes (proc, sysproc, edf, pgrp, semaphores), files (chan, qio, sysfile, cache, dev, mnt), memory (segments, pages, swap, fault, xalloc), console (devcons), time, syscalls |
| portable devices | 5,656 | devproc, devmnt (the 9P client), devpipe, devenv, devsrv, devsys, devroot, devdup, devuart |
| storage | 2,509 | devsd, sdmmc, the EMMC (Arasan SDHCI), DMA |
| keyboard, mouse | 1,779 | kbd, kbmap, kbin, latin1, devmouse |
| draw | 3,677 | devdraw, drawmesg, drawwindow..., swcursor, swconsole, screen |
| + libraries | 8,197 | libmemdraw 5,574, libmemlayer 1,339, libdraw's geometry 1,284 |
| IP | 17,574 | tcp 3,603, ipifc, devip, il, iproute, icmp6, ethermedium, ip, udp, arp, ipv6, icmp..., netif, devether |
| USB | 2,775 | devusb (the endpoints as files), usbdwc (the DWC2) |
| ARM machine | 6,273 | boot, MMU, traps, clock, vcore (mailbox, framebuffer), mini UART, VFP |
| **total** | **~67,500** | (59,308 compiled in the kernel's own files) |

Its user interface, which mini-9pi must keep exactly (principia's
programs are compiled against it):

- **System calls**: 40 (principia's numbering, not Bell Labs' nor
  9front's: `lib_core/libc/9syscall/sys.h`; rfork, exec, exits, await,
  brk, open ... errstr); the number in R0, `SWI 0`, the arguments on
  the user's stack from sp+4 (as xv6 arm-pi1's: mini-xv6's Pi1 Arch
  already reads them there), the result in R0, errors by errstr.
- **Executables**: Plan 9's a.out (magic 0x647, a 32-byte big-endian
  header), text at UTZERO 0x1000 (header included), data and bss
  after; the stack below USTKTOP 0x20000000 (8MB), the Tos at its top;
  exec returns the Tos's address in R0.
- **Notes** (Plan 9's signals): a frame pushed on the user's stack, the
  handler entered, `noted` to return.
- **The boot**: the kernel's first process runs initcode (from the
  kernel), which binds `#c` and execs `/boot/boot` -- an rc script
  (`boot.rc`) from the kernel's **bootdir** (rc, rcmain, echo, bind,
  fdisk, dossrv, mount, ls: 777KB of principia's binaries linked into
  the image). It binds the devices, partitions `#S/sdM0`, starts
  **dossrv** (the SD card's FAT partition: there is no other file
  system), mounts it as the root, starts ramfs and usbd, and runs an
  interactive rc.

Graphics and input: the framebuffer by the mailbox; devdraw serves
`/dev/draw` (libdraw's protocol: `drawmesg`) over libmemdraw and
libmemlayer, a software cursor; the keyboard and mouse are USB devices
driven **in user space** (usbd enumerates through the kernel's devusb,
`usb/kb` writes `#Ι/kbin` and `#m/mousein`). rio needs `/dev/draw`,
`/dev/mouse`, `/dev/cursor`, `/dev/cons`, `#|`, `/srv`, a mount on
`/mnt/wsys`, fonts from the card.

Networking: devip and its protocols are configured in, **but no NIC
driver** (`etherusb` is commented out in the conf; boot.rc's network
lines too): the Pi1's LAN9512 (smsc95xx) is one QEMU does not model.
QEMU's `usb-net` (CDC ECM or RNDIS) could be attached to the Pi1's
DWC2; principia's user-level `usb/ether` has a minimal CDC reset, but
usbd has no entry to start it for a class-2 device. So **there is no C
reference for networking**: no test can say "as 9pi does".

The earlier attempt, `~/xix/kernel` (2017; 3,635 lines of OCaml over a
C Plan 9 port, bytecode, on a Pi2): threads and a timer worked; the
system calls beyond 8 are stubs, no file, namespace or device exists;
it never ran a user program. mini-xv6's ladder (kernel/step1-5) is why
this plan starts from a running kernel instead.

## Decisions (the author, 2026-09-26: "I like your plan"; 5 and 6 open)

1. `kernel/lib/` for what is shared with mini-xv6; the Pi1 first.
2. **Not byte for byte**: the sessions checked against 9pi's, but a
   twin free where exactness costs; of the 40 system calls, some wait
   (the shared segments' segattach, segdetach, segfree, segflush,
   segbrk, among the first).
3. Records and variants as appropriate; for 9P, the author's own
   design in `~/xix/lib_core/system/plan9/Protocol_9P.mli` (Request and
   Response variants, a message a record of its tag and its type;
   `Plan9.mli`'s qid and directory entry) -- ported, not linked (xix is
   today's OCaml over Unix; mini-9pi is ocaml-light's, on a Pi1 where
   Int64 is not reliable: offsets are ints).
4. The C pixel libraries (libmemdraw, libmemlayer) linked first, to
   reach rio sooner; **then ported to OCaml** (stage F).

The proposals as written before:

1. **Where, and what is shared.** `kernel/9pi/`, on mini-xv6's
   machine layer: `pi1/`'s boot, traps and switch (`start.s`),
   `runtime.c` (the processes' stacks and the collector), `libc.c`,
   `usb.c`, and the OCaml `Machine`, `Arch`, `Mmu`, `Screen` where they
   fit. Proposed: the shared parts move to `kernel/lib/` (ix's
   convention allows a library for code really shared), each kernel
   keeping what is its own. **The Pi1 only** at first: 9pi is a Pi1
   kernel, principia's userland is arm32; the Pi4 is later (arm64
   user programs from principia's 7c, if they exist).
2. **Fidelity.** A mini twin: principia's 40 system calls and their
   semantics, its a.out, its devices' file trees and their text formats
   (`/dev/sysstat`, `/proc/n/status`...), so that the boot's console and
   a session print what 9pi prints, byte for byte (`raspberry/tests/
   9pi.py`'s session), and the screens are 9pi's (`9pi_graphics.py`).
   What 9pi has and a one-core, non-preemptive kernel with no disk
   swap does not need -- locks, swap, EDF scheduling, the page cache's
   subtleties -- goes, and the plan says so, as mini-xv6's did.
3. **The shape: the namespace as data.** Plan 9's kernel is its
   devices behind one interface (attach, walk, stat, open, read, write,
   create, remove, wstat) and the channels that name them; in OCaml, a
   `Dev` record of functions per device, `Chan`, `Qid`, `Dir` as
   records, the mount table a map, 9P's messages a variant (devmnt: the
   client, the one talking to dossrv, ramfs, rio). This is where OCaml
   should be clearest, and the plan's core.
4. **Draw: link the C libraries, or port them.** libmemdraw and
   libmemlayer (6,900 lines of pixel code) are deterministic and
   self-contained. Proposed: **link principia's C first** (compiled by
   gcc into the kernel, as the OCaml runtime's C is), with devdraw's
   protocol in OCaml, to reach rio; then port memdraw to OCaml as its
   own step, checked pixel for pixel against the C on the host (a
   differential test, as random_blocks is for the CPU).
5. **Networking: which NIC, and whose driver.** No C reference exists,
   so the test is against the host: a TCP connection through QEMU's
   user networking (slirp: 10.0.2.2). Options:
   - (a) QEMU's **usb-net** in CDC ECM mode, driven by principia's
     user-level `usb/ether` -- needs a usbd entry for class 2 and
     boot.rc's network lines, i.e. **changes to principia** (its
     userland, not its kernel);
   - (b) the same device, driven by **mini-9pi in the kernel** (an
     `etherusb`-like driver on `Usbhost`, `#l0` appearing by itself):
     principia untouched, the session typing `bind -a '#l0' /net` and
     `ip/ipconfig` itself.
   Either way **mini-qemu needs a usb-net** and a way to the host's
   network (a small user-level NAT of its own, or a tap device):
   comparable in size to the USB work of phase J.
   And the IP stack: **a subset ported to OCaml** (ipifc, arp, ip,
   icmp, udp, tcp: ~9,000 lines of C; no il, no IPv6), devip's files
   kept exactly (ipconfig, ping, dial use them).
6. **May principia change?** ~/xv6 and ~/ocaml-light stayed untouched;
   option 5a changes principia's usbd table and boot.rc (and a fix
   there would help the C 9pi too). The author's call.

## The stages (each checked before the next)

- **A. A Plan 9 process.** The a.out loader, the Tos, the stack; the
  system calls a first program needs (brk, open, read, write, exits,
  errstr) over `#c` (cons) and `#/` (a root with the bootdir, embedded
  as fs.img is in mini-xv6); `/boot/echo hello` runs. Checked: its
  output, under mini-qemu and QEMU.
- **B. The namespace.** Chan, walk, the mount table, bind, mount;
  devmnt (9P: version, attach, walk, open, read, write, clunk, stat);
  pipe, srv, env, dup, proc (enough for rc), rfork (its flags: the
  namespace, the fd table, memory), await, notes. Checked: rc from the
  bootdir running a script.
- **C. The boot to rc's prompt.** The SD card (devsd over the EMMC and
  DMA: the Arasan controller and the Pi's DMA engine, as mini-qemu's
  `Sdhost` and `Dma` model them), dossrv serving it, boot.rc to the
  end; mini-qemu's `9pi.py` session (ls, cat, wc, a pipe, the card's
  ctl, a file written and read back): **the console byte for byte
  9pi's**.
- **D. Graphics.** The framebuffer, devdraw and its protocol, the
  software console (the "Plan 9 Console" window) and cursor; devusb
  and the DWC2 for usbd and usb/kb; devkbin, devmouse, the keyboard
  maps. Then rio: `9pi_graphics.py`'s session -- the console, then rio's
  menu, a window, a command in it: **every screen 9pi's**.
- **E. Networking.** As decided in 5: the NIC, its driver, devether,
  devip and the protocols; mini-qemu's usb-net and its way out. Checked
  against the host (a TCP echo through slirp), under mini-qemu and
  QEMU.
- **F. memdraw in OCaml** (if decision 4 links C first), pixel for
  pixel against the C.

## Size, expected

mini-xv6's kernel was 1,036 lines of OCaml for xv6's ~4,300 of C. A
Plan 9 kernel is a larger design: 9pi's portable core, devices and
storage are ~27,000 lines of C, draw's protocol ~3,700 (plus 8,200 of
libraries), IP ~17,600. A guess, to be replaced by counts: A-C 5,000 to
8,000 lines of OCaml, D 2,000 to 3,000 (C libraries linked), E 3,000 to
5,000. Several weeks of the pace kernel/xv6 had.

## Status

2026-09-26: plan written, from the survey; decisions 1-4 settled
(above), 5 (the NIC and its driver) and 6 (may principia change) open:
they matter at stage E.

2026-09-26, **stage A done**: `kernel/9pi/` (865 lines of OCaml with
comments, over `kernel/lib/`) boots on the Pi1 and runs principia's own
`/boot/echo hello` from the bootdir. The console says `mini-9pi`,
`hello`, then `panic: boot process died: unknown`: 9pi's own panic when
its first process exits, since exits(nil) leaves no status. `make check`
compares that console under mini-qemu and under QEMU with `expected`.
The pieces:

- `Types` has the qid, the open mode, the channel, the segments and the
  process as records and variants; `Error` is Plan 9's error(), with
  principia's messages.
- `Dev` is the device interface: a record of functions (attach, walk,
  open, read, write, close) per letter, plus Dirtab-style trees.
- `Devroot` serves `#/`: the root's mount-point directories and `/boot`,
  whose files are read in place from the kernel's image
  (`mkbootdir.py`, in 9pi's order).
- `Devcons` serves `#c`: cons, cooked as Plan 9 cooks it, with a CR
  before each LF as 9pi's UART sends it; and null.
- `Chan` has namec, which turns `/`, `.` and `#x` paths into channels
  (a missing element reports `'path' file does not exist`, as
  nameerror does), and the descriptors.
- `Exec` loads the a.out: text with its header at 0x1000, then data and
  bss. It runs `#!` scripts with argv[0] set to the script's name, and
  lays out the stack, argv and Tos byte for byte as sysexec and
  arch_execregs do. R0 gets the Tos's address.
- `Syscall` dispatches principia's 40 numbers, with the arguments at
  sp+4 and vlong offsets taken as two words. Implemented: nop, exec,
  exits, brk (ibrk on the bss), open, close, pread, pwrite, errstr. The
  others fail and the console names them.
- `Main` holds the traps. Its first process does initcode's opens in the
  kernel (as mini-xv6's init does), then the exec.

Simplifications, for now: the stack's top 64 pages are given at exec,
so there are no demand faults. All pages are the user's to write (text
isn't read-only yet). DMDIR is not in the permissions, because a Pi1
int has 31 bits; a directory is known by its qid's type.

What stage B starts from: with `/boot/boot` as the first program, rc
(158KB, run through `#!`) starts and reads rcmain. It then fails on
exactly the missing pieces, in this order: notify; create in `/env`
(`#e`, and initcode's binds); rfork.
