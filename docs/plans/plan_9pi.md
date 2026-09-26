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

2026-09-26, **stage B, first part**: 2,127 lines of OCaml. boot.rc now
runs as `/boot/boot`, the way 9pi runs it. It prints
`booooooooting ARM ...`, binds `#e #ec #s #p #d #k #P`, writes
`#c/swap`, and reaches `partition...`, where the C 9pi goes on to its
SD card (stage C). `make check` has this boot under both emulators. It
also has a second image whose `/boot/boot` is `tests/boot-b.rc`: boot.rc's
first lines, then an interactive rc typed `tests/session-b.cmds`. That
session covers `ls` of `/boot`, `/env`, `/dev` (the union of `#c` and
`#P`) and `/fd`, variables and functions, `cd`, a pipe into another rc,
command substitution, `>` into `/env`, `$status`, and a missing command.
Its console is the same under mini-qemu and QEMU (`tests/session-b`).

What was added:

- The namespace. `Chan.namec` cleans absolute paths lexically (as
  cleanname does), and at each mount point it walks the union's members
  in order (Plan 9's domount and umh). Binds support MREPL, MBEFORE,
  MAFTER and MCREATE; create goes to the first MCREATE member;
  directory reads go over the whole union. Chans are reference counted
  (cref), so a descriptor table copied by rfork shares its chans, and a
  pipe hangs up at its last close.
- Processes. rfork implements its flags (the fd, name and env groups:
  copied, cleaned or shared; RFNOWAIT; RFNOTEG). The memory is copied
  per segment with `Mmu.copy_range`, new in kernel/lib: a Plan 9 stack
  is at 512MB, far above the rest. await returns pexit's records, last
  child first, formatted `%d %lud %lud %lud %q`.
- System calls: create, remove, chdir, dup, fd2path, seek (its vlong
  result goes through the first argument, as 5c returns it), stat and
  fstat (with the name set to the path's last element), wstat, pipe,
  bind, unmount, sleep. notify only records the handler.
- Devices: `#e` (devenv's behavior, including remove moving the last
  entry into the hole), `#s`, `#|`, `#d`, `#k`, `#P`, `#p` (status,
  args, fd, ns, segment, noteid, ctl kill), and `#c` with consdir's
  files and echo as typed.
- The stat format is in `Dev` (convD2M and convM2D). DMDIR is written
  from the qid's type, and wstat's "unchanged" ~0 decodes as -1.
- kernel/lib: the build directory and the image can be overridden
  (`start.s` finds its images with `as -I`). session.py gained
  `--prompt` and `--lines`.

Still missing from stage B: devmnt and 9P (mount, fversion, fauth),
which the SD card's dossrv needs, so they come with stage C. Notes
(their delivery, noted), alarm, rendezvous and semaphores, RFMEM, and
demand paging (the stack's top 64 pages are still allocated at exec).
Also the clock that `ls -l` dates come from (1970 here, the C's
`Sep  9  2026`), and eve before boot.rc names the hostowner.

2026-09-26, **stage C: the boot to rc's prompt** (3,124 lines of
OCaml). mini-9pi boots principia's own SD card (`qemu-sd.img`) as 9pi
does. boot.rc partitions `#S/sdM0`, dossrv serves the FAT, and the
card is mounted on `/root` and bound to `/`. `/arch/arm/bin` and
`/rc/bin` join `/bin`, then ramfs, mkdir and the hostowner write run
from the card, and finally rc's prompt. On that prompt, 9pi.py's
session (ls, echo, `ls -l` and `cat` of `/dev/sdM0`, a file written
and read back, `wc` of a directory's listing and of a file, `hoc`)
gives the **C 9pi's console under QEMU byte for byte, but for one
number**: hoc's pid, 40 against 9pi's 48, because 9pi's usbd starts
processes that need `#u` (stage D). mini-9pi's own console is the same
under mini-qemu and QEMU (`make check`: `tests/session-c`).

What was added:

- `Emmc` (emmc.c and sdmmc.c): the Arasan controller and its card,
  polled by PIO through the data port (9pi uses DMA and an interrupt),
  and brought online with sdmmc's sequence. Registers are read in
  16-bit halves and written from halves (`Machine.io_get16`, `io_set32`,
  `io_read_fifo`, `io_write_fifo` in kernel/lib's runtime.c).
  **Bug found**: the RCA argument, `rca lsl 16` = 0x45670000, is past
  the Pi1's ints, and bit 31 came out set. mini-qemu ignores that
  argument, but QEMU's card timed out on CMD9.
- `Devsd` (devsd.c): `#S/sdctl`, `sdM0/{ctl,raw,data,parts}` with
  devsd's qids, ctl text, the part and delpart commands, and sdbio's
  block arithmetic. The data partition's length is 2^30, one past a
  Pi1 int, so a directory entry now carries `d_lenhi` (its 2^30s).
- `P9` (xix's Protocol_9P design): Request and Response variants and a
  message record `{tag; mtyp}`, with the client's encoding and
  decoding.
- `Devmnt` (devmnt.c): a session per connection (Tversion), Tattach per
  mount, a fid per chan, and walks one element at a time with the
  intermediate fids clunked. A clone takes its own fid (a 9P fid can't
  be walked once opened). Reads and writes are split to the msize, and
  a small mountmux hands each reply to its tag's waiter. mount, fauth
  and fversion are system calls now.
- Demand paging (`Fault`): exec reads only the header and writes only
  the argument pages of the stack. Text and data pages come from the
  program's chan at their first touch, bss and stack pages as zeros.
  System calls fault user buffers in first (validaddr), and brk only
  moves the top. The Pi1's abort entry now backs its saved pc up to the
  faulting instruction, so the kernel can restart it.
- Traps as 9pi's notes: an undefined instruction (5c's FPA code: hoc)
  or a bad fault prints `text pid: suicide: msg` on the process's fd 2
  and exits with that message. The Pi1's undefined-instruction entry
  now sends user-mode traps to the process rather than halting, and
  reports a data abort's write as arm64's WnR.
- Plan 9's scheduling: a FIFO run queue, a 100ms slice (hzsched), and
  cooperative handing over (cpu->readied: a woken server answers at
  once). **A divergence**: a process woken while the CPU was idle gets
  a fresh slice (9pi keeps the stale one). Otherwise `echo 1.5*2 | hoc`
  raced: under mini-qemu a tick preempted echo, hoc died first, and
  echo printed a write error that the C 9pi doesn't.
- Times, qid paths and versions are carried as their low 31 bits,
  since a time after 2004 is past 2^30 (good until 2038). The devices'
  files carry 9pi's own KERNDATE, the mtime of principia's `pi.5`,
  passed in the bootdir's header, so `ls -l` shows 9pi's dates.

Still missing: `#i` (draw), `#I` (IP) and `#u` (USB) are still
"unknown device" when boot.rc binds them or runs usbd (stages D and E).
Notes are not delivered to handlers. Fids are leaked by chans that are
dropped without being opened (a stat by name clunks its own), and
there's no MCACHE.

2026-09-26, **stage D, step 1: what threaded programs need** (3,472
lines). Stage D is now four steps: (1) the processes' machinery, (2)
USB (`#u`, usbd, usb/kb), (3) the framebuffer and `#i` (draw), (4) rio.
Step 1 is done. plumber, a libthread program from the card, runs as on
the C 9pi: two processes sharing memory (Pread and Rendez in `ps`), its
`/srv` post and its mount, its errors, and its end by a note (`kill
plumber | rc`). `make check`'s new session (`tests/session-d`) covers
sleep, a background process killed by its note, and plumber. It is
the same under mini-qemu and QEMU, and the C 9pi's for the lines that
don't depend on usbd (rc's pid, the mount number).

- **Shared memory.** Pages belong to segments, as in Plan 9: a table
  from address to page, and a share count. A process's page table only
  caches them: a fault maps a page another sharer made, or makes it.
  rfork shares text always, data and bss with RFMEM, and copies the
  stack. Exec and exits release the segments, and the last sharer
  frees the pages. brk refuses to shrink a shared segment (Einuse), as
  ibrk does.
- **Notes**, as arm's notify and noted:
  - a note is posted (NNOTE 5; a kill's note alone when the process has
    no handler for it), which interrupts a sleep ("interrupted") or
    gives up a rendezvous;
  - it is delivered on the way back to user mode, after a system call
    (but rfork), an interrupt or a fault, on a 216-byte NFrame below
    the user's sp;
  - a `sys:` note gets ` pc=0x...`;
  - without a handler, a trap's note prints `suicide:` on fd 2 and ends
    the process;
  - noted handles NCONT, NRSTR, NSAVE and NDFLT (the PSR's flags stay the
    current ones, as arch__noted's mask keeps them);
  - exec resets the handler.

  The user's registers are moved as bytes (kernel/lib's `tf_bytes`),
  because a negative register or the PSR's N flag doesn't fit a Pi1
  int. `/proc/n/ctl`'s kill is the note `sys: killed` (NExit), and
  `note` and `notepg` post notes.
- **rendezvous** (a group per RFREND; the last waiter on a tag found
  first), **the semaphores** (semacquire, tsemacquire, semrelease: with
  one core and no preemption in the kernel, a decrement or a sleep on
  the word's physical address), and **alarm** (the tick posts `alarm`).
- **9pi's walk, errors included.** Paths are walked as given, not
  cleaned (".." is lexical, from the chan's name), and `#` paths cross
  no mount point. A name missing at the first name of a batch (from a
  mount point to the next) gives the union's *last* member's error;
  further into a batch, "does not exist" (9pi's partial walk). The name
  printed is the path as typed, up to the missing name
  (`'//lib/plumbing' does not exist`). An open's or create's error names
  the whole path (namec's).
- **Details as 9pi's:** devdir's atime (the uptime; 9pi's clock starts
  at 0) and muid (the owner). KERNDATE is found in 9pi's image
  (`kerndate.py`), `/srv` entries have their maker as the owner,
  `/proc/n/status` sums the segments but the stack, and a mount
  chan's number is per attach or auth (mntchan's).

Not exercised by a program yet: tsemacquire, alarm, NSAVE. Stage C's
and step 1's sessions differ from the C 9pi only by what usbd changes:
its pids, mount numbers and `/srv/usb`. Step 2 (`#u`) should close
that gap.

2026-09-26, **stage D, step 2a: USB's `#u`**. `Usb` (usb.h's types),
`Usbdwc` (usbdwc.c: control, interrupt and bulk transfers, data toggles,
NAKs retried, the root port, over kernel/lib's polled `usb_transfer`;
split transactions skipped as 9pi skips them under emulation) and
`Devusb` (devusb.c: `#u/usb/ctl`, `epN.M/{data,ctl}`, the ctl commands,
the root hub's toy replies). boot.rc's usbd now runs as on 9pi: its four
processes (work, usbfs, outproc, fsioproc, named by threadsetname:
`/proc/n/args` is procargs'), `/srv/usb`, its mount on `/dev`. With
QEMU's USB keyboard and mouse it enumerates the hub, the keyboard and
the mouse through mini-9pi's `#u` (usb/kb then stops at `#Ι/kbin` and
`#m/mousein`: step 2b). `#i` and `#I` exist as empty directories until
their stages. The pids 9pi's kernel processes take (kgenrandom, alarm,
kpager at the swap's start, rxmitproc at `#I`'s attach) are spent at
the same moments, the boot process has userinit's environment
(terminal, cputype, service, etherargs), a forked child has no
arguments: **9pi.py's session is now the C 9pi's byte for byte** from
rc's first prompt on, hoc's pid (48) included.

A compiler bug found on the way: with the USB devices attached the
kernel crashed in the OCaml collector. The ocaml-light fork's ARM
backend gave calls made while an argument is on the stack (an
application of more than 8 arguments: Printf with 8 or more) a frame
descriptor 4 bytes too big (plan_bugs_ocaml_light.md, bug 5). Fixed by
upstream OCaml's rounding of the outgoing area, as a patch
`kernel/ocaml-light.sh` applies to its clone
(`kernel/ocaml-light-patches/`). The hunt is written up in
`docs/notes_debugging_techniques.md`, technique 8.

2026-09-26, **stage D, step 2b: the USB keyboard and mouse**. `Kbd`
(portkbd.c's kbdputsc and its five tables: scan codes to runes, the
escapes, shift, ctrl, caps; compose sequences, latin1, not yet),
`Devkbin` (`#Ι/kbin`: a device letter that is a rune, U+0399, so
devices now have a `drune` and `#` paths decode UTF-8) and `Devmouse`
(`#m`: mouse, mousein, mousectl, cursor, devmouse's queue of clicks and
its formats; the position clamped to a screen there is none of yet, so
moves wait for step 3, as 9pi's without a gscreen). With QEMU's
usb-kbd and usb-mouse, usbd starts usb/kb for both, and **a session
typed on the USB keyboard** (session.py --usb, which now types a US
keyboard's printable characters, shifted ones with shift) gives the C
9pi's console byte for byte, under mini-qemu and QEMU (`make check`:
`tests/session-usb`). Not the same yet: `ps`'s order of usbd's
processes when two start together, `kbd repeat`'s state, usbd's size
(4K): timing.

2026-09-26, **stage D, step 3a: the screen and the cursor**. principia's
pixel libraries (decision 4: libmemdraw, libmemlayer, a few of
libdraw's files) are compiled by gcc as Plan 9 C (`-fplan9-extensions`,
`p9gcc.h`, principia's headers) and linked in (kernel.mk's
`EXTRA_OBJS`). `draw9.c` gives them the Plan 9 libc they call (mallocz,
werrstr, print, qsort, the image pool, EABI's 64-bit division...) and
the kernel an interface (`d9_*`); `drawglue.c` makes it OCaml's
(`Draw`: an image is a C pointer, outside the OCaml heap). `Swconsole`
draws the console as 9pi's swconsole.c and screen.c's screenwin do (the
framebuffer first all 0x7F, fbinit's "blue screen"; the black frame,
the white window, the orange title bar and " Plan 9 Console ",
scrolling by 8 lines), and `Swcursor` is swcursor.c (the arrow, what it
covers kept aside, hidden by any drawing over it, as memdraw's hwdraw
hook does; redrawn by the clock at the mouse's position). The boot
prints 9pi's banner and devices' resets. **The screen is the C 9pi's
pixel for pixel** after a session and after the USB mouse moved (usb/kb's
accelerated moves), under mini-qemu and QEMU (`make check`:
`tests/screen-c.ppm.gz`, `tests/screen-move-c.ppm.gz`, made by
`make expected-screen`). `mini-pi -g mini-9pi` opens it in a window.
QEMU warns of a re-entrant I/O on bcm2835-fb at the framebuffer's
mailbox request, for the C 9pi as for mini-9pi: filtered out of the
sessions. Next, step 3b: `#i`, devdraw's protocol, over the same
libraries.

2026-09-26, **stage D, step 3b and step 4: `#i`, and rio**. `Devdraw`
is devdraw.c and drawmesg.c (with drawalloc.c, drawname.c,
drawwindow.c, drawmisc.c): the clients (`/dev/draw/new`, `n/ctl`,
`data`, `colormap`, `refresh`), their images by number, the names
(the screen's "noborder.screen.1"), fonts' characters, screens and
their windows, the refreshes of windows refreshed by messages; every
message of draw.h's protocol parsed in OCaml. Their pixel work is
principia's libraries' still (decision 4): `draw9.c`'s d9_* (an image
allocated and filled, a drawing with its op, lines, polygons,
ellipses and arcs, pixels loaded and read, memlayer's windows), the
message's ints passed as an int array, a 32-bit chan or colour as its
halves. The cursor avoids a drawing as on 9pi: memdraw's hwdraw
(draw9.c's, 9pi's screen.c's) calls `Swcursor.avoid` back (so OCaml's
collector may run inside a drawing: a primitive takes its arguments'
ints, and copies of their strings, first). Not as 9pi: no flushes (on
the Pi, 9pi's do nothing), no blanking, the colormap's colours 0.
**`colors` draws the C 9pi's screen pixel for pixel**, and **rio**:
`graphics.py` (raspberry/tests/9pi_graphics.py's steps: lines typed at
the console, the mouse moved, rio started, its menu, a window swept
out, `echo hello from rio` typed in it) gives the C 9pi's 11 screens and
console, under mini-qemu and QEMU (`make check`: `tests/rio-c.md5`,
`tests/rio-c.txt`, from `make expected-rio`). `mini-pi -g mini-9pi`
runs rio in a window. Stage D's goal is reached; next, stage E
(networking) or F (memdraw in OCaml).
