# Debugging techniques, written up as they get used

Notes on *how* problems in ix were tracked down, each technique with the
real case that earned it (mostly from kernel/9pi/, mini-9pi, and its
twin reference, principia's C 9pi, under QEMU and mini-qemu). What the
bugs were belongs to the plans (docs/plans/plan_9pi.md's status); this
file is about the method. Add a technique when a real session earns
it, not before.

## 1. Diff against the reference, with the very same inputs
mini-9pi is a twin: for every behavior there is an answer, the C 9pi's.
So the first move for any doubt is not to reason about what Plan 9
"should" print but to ask it. A small script boots the C kernel under
QEMU, types a file of commands at rc's prompt, and saves the console
(the scratchpad's c9pi.py, cut from raspberry/tests/9pi.py: its SESSION
read from argv[1], its output written to argv[2]); session.py
--lines does the same for mini-9pi. Then diff:

```
c9pi.py cmds.txt ref.txt
session.py --prompt "% " --lines cmds.txt -- Main.exe ... > mine.txt
diff <(sed -n '/% first-command/,$p' mine.txt) \
     <(tr -d '\r' < ref.txt | sed -n '/% first-command/,$p')
```

Real finds this way, each one line of diff:
- a walk error: '//lib/plumbing' does not exist (9pi) against
  '/lib/plumbing' file does not exist (mini-9pi): two bugs, the path is
  printed as typed (not cleaned), and a name missing past the first of a
  batch is "does not exist" (walk's Edoesnotexist);
- ps's sizes, 184K against 180K: 9pi's boot process has four variables
  userinit set (terminal, cputype, service, etherargs), so rc's heap was
  a page bigger;
- ls -l's dates, 2094 against 2026 (see 3).

The pitfall: the inputs must be identical, the *whole* sequence. A
"mystery pid" (ps was 38 in the C, 37 in mini-9pi) cost an hour of
reading usbd's source; the cause was that the C session had run one
command (cat) before ps and mine had not. Re-running both with the same
command file made the difference vanish. When a number differs by one,
first check the two sessions typed the same things.

## 2. Two emulators as a cross-check
Every mini-9pi check runs under mini-qemu *and* QEMU. When one passes and
the other fails, the bug is where the two emulators differ in what they
check, and the kernel was relying on what the lenient one ignores.
The SD card came online under mini-qemu but not QEMU ("i/o error"); a
diagnostic the C driver has (emmccmd's "emmc: cmd %ux error intr %ux
stat %ux", added to Emmc.ml, timeouts included for the hunt) printed:

```
emmc: cmd 9010000 error intr 18001 stat 1ff0000
```

Decoded by hand: command 0x09 = CMD9 (SEND_CSD), intr 0x18001 = Cmddone |
Err | Ctoerr: a timeout. CMD9's argument is the RCA shifted by 16,
0x4567 lsl 16 = 0x45670000 - past the Pi1's 31-bit ints (technique 3):
the C primitive wrote 0xC5670000. mini-qemu's card ignores CMD9's
argument; QEMU's checks it. Lesson: port the reference's own error
messages first, then read them in hex against the spec.

## 3. The Pi1's 31-bit ints: recognize the symptom, then find the 2^30
On the Pi1, an OCaml int holds -2^30..2^30-1. Anything a 32-bit machine
calls normal breaks silently: 1 lsl 30 is min_int, 0x80000000 does not
compile, a register with bit 31 set comes back as garbage. The symptom
is always an absurd number; the move is to write it in hex and look for
bits 30 and 31:
- ls -l's length 2305843008139952128 = 0x2000000000000000: the 1GB
  partition's "sectors per 2^30" computed with 1 lsl 30 (negative);
- a date in 2094: the kerndate (2026 = 0x6aa0e987) has bit 30 set, and
  le32 sign-extended it into bit 31;
- CMD9's RCA argument (above);
- DMDIR (bit 31) in a create's perm: get_le32 returned max_int.
The fixes follow one pattern: move 32-bit values as bytes or 16-bit
halves at the boundary (Machine.io_get16/io_set32, tf_bytes, P9's u31
fields), keep inside OCaml only what fits, and name the representation
in the .mli (d_lenhi, perm's sign as DMDIR).

## 4. A system call trace, filtered so it does not break the test harness
Syscall.trace (off; set it in Main's boot to use it) prints each call
"[pid Name args][pid = result]". Three bugs fell to it:
- command substitution hung: the trace showed pipe's fds, the fork, the
  child's write and exit, but the parent's read never returned; reading
  pipe's code again: it attached #| three times (namec "#|", "#|/data",
  "#|/data1"), so the ends were two different pipes. Plan 9's syspipe
  walks both ends from one attach.
- `echo 1.5*2 | hoc`: echo's process made no system call until hoc was
  dead (see 5).
- usbd's mount "missing" from pid 1's namespace: the trace showed the
  Mount call returning 5, success (see 7).
The trace's own output lands on the console, so session.py no longer
sees rc's "% " at the end of the output and waits forever. Filter it:
by call (`match c with Rfork | Exec | Exits -> true`), by pid (`p.pid >=
28`), or stop the session on a string (`--until "echo: write"`) instead
of the prompt. And when the output is a wall, `tr ']' '\n' | grep -E
'^\[(29|30) '` keeps one or two processes.

## 5. Confirm a race by turning its suspected cause off, then fix it the reference's way
`echo 1.5*2 | hoc` printed an extra "echo: write error" under
mini-qemu. The trace showed echo's side preempted by a clock tick
before its exec, while hoc ran to its death and closed the pipe. To
confirm, not guess: make preempt_due return false (one edit), rerun: the
extra line went away. Cause proven; but the fix is not "no
preemption" - it is reading how 9pi schedules (proc.c's ready/runproc,
hzsched): a FIFO run queue, a 100ms slice, and cpu->readied (the process
just woken runs next: a server answers its client at once). mini-9pi
took all three; the one remaining divergence (a process woken while the
CPU was idle gets a fresh slice) is documented as such. Timing races are
where a twin's output can differ without a bug: when the C itself only
wins the race by being fast, say so in the plan rather than chase it.

## 6. Read the reference's function, stripped, before writing its twin
principia's sources are syncweb-tangled: `/*s: ... */` markers on every
chunk. To read one function whole:

```
grep -v "/\*[sex]:" files/chan.c | awk '/^walk\(/,/^}/'
```

Most fidelity bugs were details only the source shows: pexit pushes a
wait record at the head (await returns the last child first); devenv's
remove moves the last variable into the hole; a note starting "sys:"
gets " pc=0x..." at delivery; exec resets the note handler (hoc died
of rc's handler until exec cleared it: "sys: trap: fault read va=0x0"
instead of "undefined instruction"); procargs quotes each argument and
a thread's name shows as "text [name]"; devdir's atime is seconds()
while its mtime is kerndate. When a reference value is one second off
(KERNDATE from pi.5's mtime: 1788930440 against 9pi's 1788930439),
decode the reference's raw bytes (struct.unpack on the stat entry) and
find the real constant in its binary (kernel/9pi/kerndate.py).

## 7. Distrust your own diagnostic output as much as the program's
usbd's mount of /srv/usb on /dev seemed absent from `cat /proc/1/ns`.
It was there: mini-9pi's /proc/n/ns printed a mount as "bind /dev /dev"
(its member's name is the mount point's), so it hid among the binds.
The trace (4) showed the Mount succeed, which is what exposed the
misleading printer. When a diagnostic tool of your own says something
surprising, check the tool against a second source before chasing the
program.

## 8. A crash in the collector: from the address to a compiler bug (a worked case)

The whole hunt, because each step is a technique and two of them were
dead ends worth knowing. The symptom: with QEMU's USB keyboard and
mouse attached, mini-9pi died a few seconds after rc's prompt,
deterministically:

```
mini-xv6: in the kernel, data abort, lr 800447d0, far 00000000
```

**Name the address.** The board's C (lib/pi1/machine.c's kfault)
prints the abort's lr; kernel.elf keeps its symbols:

```
arm-linux-gnueabihf-addr2line -f -e build/pi1/kernel.elf 0x800447d0
arm-linux-gnueabihf-nm -n build/pi1/kernel.elf | awk '$1 <= "800447d0"' | tail -3
```

`oldify_local_roots`: the OCaml collector, walking a stack's frames.
That names suspects, not the bug: a C primitive allocating without
registering its values (CAMLparam), a kernel stack (16KB) overflowed
into its neighbour's, a stale view of a stack. The crash reproduced
under QEMU too (so not an emulator bug), and at a fixed address (so
not random memory corruption).

**Test a hypothesis with a knob, and believe the result.** Kernel
stacks from 16KB to 64KB: same crash, same address. Not an overflow
(the layout changed, the crash did not). Reverted.

**Narrow with a debug print of the device's work.** A switchable print
of each USB transfer (Usbdwc.debug) showed the last transfer before the
crash: a control read of 4096 bytes, the size of the DMA page. Another
hypothesis (the DMA writing past its page), checked in the emulator's
source (raspberry/Dwc2.ml writes the device's bytes only): out.

**A theory that explained too much.** Reading kernel/lib's runtime.c,
I found what looked like a latent bug (after a return to user mode from
inside OCaml, the runtime's `caml_bottom_of_stack` names abandoned
frames) and "fixed" it. The crash came *earlier*. A fix that makes
things worse is evidence against its theory: it was reverted, and the
right move was to stop reasoning and look.

**Look: gdb on QEMU, stopped at the exact instruction.** The fault is
`lr - 8` (an ARM abort). Its disassembly showed a hash-table probe
(`ldr r2, [r4]`, r4 a frame descriptor); stop there only when it fails:

```
qemu-system-arm ... -gdb tcp::12399 -S &
gdb-multiarch -batch -ex "set architecture arm" -ex "file build/pi1/kernel.elf" \
  -ex "target remote localhost:12399" \
  -ex "break *0x800449f0 if \$r4 == 0" -ex "continue" \
  -ex "info registers" -ex "x/24wx \$r5 - 16" -ex "bt 8"
```

Mapping registers by the prologue's loads (r7 the runtime's globals, r5
the walked sp, r1 the return address looked up) gave the key fact: the
"return address" was 0x8013e9c8, an address in `kstacks` - a saved sp,
not code. The code addresses around it on the stack, named with nm,
were the frames of the call: Printf, Usbdwc.chanio, Usbdwc.ctltrans,
Devusb's write, Syscall. One frame's size was wrong by exactly the
distance between where the return address really was (0x8013e974) and
where the walk read it.

**Read the compiler's own frame table, not a hand-parsed binary.**
`ocamlopt -S` (in a copy of the build directory, with its .cmi/.cmx)
writes the frame table as text: each call's label, frame size, live
slots. ctltrans's descriptors were right (24 + 8 for its `try`), but in
chanio:

```
sub   sp, sp, #4        @ one argument on the stack
bl    caml_apply8       @ descriptor: 56; the real frame: 48 + 4 = 52
```

A `Printf.sprintf` with 8 format arguments is a 9-argument application,
one on the stack; the ARM backend's frame_size rounds the whole frame,
the pushed argument included, up to 8. That rounding came from an
earlier fix in the ocaml-light fork (AAPCS alignment), correct only
when the outgoing area is itself a multiple of 8, which upstream OCaml
guarantees in `proc.ml` and the fork did not. The first crash (before
my debug print existed) was the same: Devusb's `seprintep` is a
`Printf.sprintf` of 11 arguments. Fixed as upstream does, as a patch
to the compiler's clone (docs/plan_bugs_ocaml_light.md, bug 5).

What to keep from it:
- a crash inside the runtime is usually the runtime's *input* (here the
  compiler's frame table), so find what it was walking;
- eliminate hypotheses by experiments that can fail (the stack size),
  and revert what did not help;
- when the reasoning stops converging, stop at the faulting
  instruction and read memory: one stack word ended an hour of theories;
- compare the compiler's claim (the descriptor) with the machine's fact
  (the stack), and grep the generated assembly for what differs
  (`sub sp` before a call).

## 9. OCaml 1.07's errors: know the three that are not your logic
ocaml-light compiles most OCaml, but three things read like type errors
and are not:
- record fields are not told apart by type: a later record with a field
  `typ` (P9's message) makes every `{ typ = ...; vers; path }` a qid
  error ("This expression has type qid_type but is here used with type
  message_type"); give fields unique names (mtyp, dname, d_perm);
- a constructor shadows another type's: Syscall's `Rendezvous` (a call)
  hid Types' `Rendezvous of int` (a wait): "expects 0 argument(s)";
- the stdlib is 1997's: no List.remove_assoc, List.mem_assq,
  String.contains, String.iter, String.init; and String.index_from with
  a start equal to the length raises Invalid_argument (a "#c" path
  panicked the boot).
When unsure whether a construct exists, compile a three-line file with
the cross compiler before using it:

```
/tmp/ix-ocaml-light-arm/bin/ocamlopt -c w.ml
```

## 10. Build and process hygiene: know which inputs a build used, kill by PID
- A test image (kernel-pi1-b.img, its own B=build/pi1-b) silently
  overwrote the main image's bootdir: the Makefile named FS from BOARD,
  not from B. Symptom: the main boot printed the test script's output.
  When output belongs to "the other configuration", list each build
  directory's inputs.
- A rule `kernel-pi1-b.img: FORCE; $(MAKE) ... IMAGE=$@ $@` recursed
  forever: inside the sub-make the target *was* IMAGE and matched the
  same rule. Guard it (ifneq ($(IMAGE),kernel-pi1-b.img)).
- Stop runaway processes by PID (ps -eo pid,args | grep ... | awk
  '{print $1}' | xargs kill), never pkill -f with a pattern that can
  match your own shell; and look for emulators left over from earlier
  sessions (ps ... | grep qemu-system) before timing anything.
