# Fuzzing techniques, written up as they get used

Notes on *how* ix's programs are fuzzed, each technique with the real
case that earned it. ix is a set of twins (mini-ed against 9base's ed,
mini-ld against goken's 7l, mini-cc against 5c and 7c, mini-ml against
ocaml-light's ocamlopt, mini-chidb against chidb...), so a fuzzer here
is almost always *differential*: random inputs through the twin and
through the reference, their results compared. What the bugs were
belongs to the plans (and the `plan_bugs_*.md` files); this file is
about the method. The companion is
[`notes_debugging_techniques.md`](notes_debugging_techniques.md): a
fuzzer finds a failure, debugging explains it. Add a technique when a
real session earns it, not before.

The fuzzers so far:

| fuzzer | twin against | compares |
|---|---|---|
| `editor/tests/fuzz.py` | 9base's ed | stdout, the file left |
| `linker/tests/fuzz.py 5\|7` | 5a/5l, 7a/7l | the executables, byte for byte |
| `languages/c/tests/fuzz.sh` | 5c -O0, 7c -O0 | the listings, instruction for instruction |
| `tiny/TinyC_fuzz.py` (with `TinyC_test.sh`) | 7c | the programs' output and exit status |
| `tiny/TinyML_fuzz.py` (with `TinyML_test.sh`) | ocaml-light's ocamlopt | the programs' output |
| `database/tests/fuzz.py` | chidb | stdout, stderr, the database files |
| `version_control/tests/diff_fuzz.py` | principia's diff and merge3 | stdout, exit status |

## 1. Differential: the reference is the specification

A fuzzer needs an oracle, something that says whether an output is
right. Writing one is as hard as writing the program; a twin gets it
for free: the reference's answer *is* the right answer. So every ix
fuzzer runs the same random input through both programs and diffs.
Nothing is asserted about what the output should be.

The payoff is the bugs no hand-written corpus found: mini-ed's regular
expressions (libregexp's threads are not in priority order, so a
memoized backtracker, correct by the textbook, answered differently:
`plan_ed.md`); Plan 9's C promoting `uchar` and `ushort` to `uint`
(TinyC, `plan_cc.md`); mini-ld's `DATA /8` writing a value's top byte
wrong when bits 62 and 63 differ (`plan_ml.md`). None of these was a
case anyone would have thought to write.

## 2. Choose what "the same" means: bytes, or behavior

The comparison's level is a design decision, and it decides what the
twin may be:

- **Bytes** where the twin promises bytes. mini-cc's compat back end is
  5c's and 7c's listing, instruction for instruction
  (`languages/c/tests/fuzz.sh`); mini-ld's executables are 7l's
  (`linker/tests/fuzz.py`, with `elfcmp.py` forgiving only the section
  table). Byte comparison catches a wrong instruction that no run
  would ever execute.
- **Behavior** where the twin is free inside: TinyC, TinyML, mini-ml,
  mini-cc's `-simple` back end (`plan_cc.md`, decision 8). The program
  is run and its stdout and exit status compared. A different
  instruction is fine; a different output is not.

The same generator can serve both: `TinyC_fuzz.py`'s programs are
compared by listing for compat (`fuzz.sh`) and by output for TinyC and
for `-simple`.

## 3. A generator that stays inside the defined language

A random program with undefined behavior is useless: the two compilers
may both be right and still differ. So the generators are built to
stay out of it, and to make every value visible:

- `TinyC_fuzz.py`: integers of every width and sign, their operators,
  conversions, loops, arrays, pointers, calls; a divisor is never 0, a
  shift is by less than the width, arithmetic wraps as the machine
  does; every variable is printed at the end. `--32` leaves out long
  long, for the 32-bit machines.
- `TinyML_fuzz.py`: **well typed by construction**, each expression
  generated *for a type*, from the variables of that type in scope
  (Pałka et al.'s generator for GHC, 2011). Loops are bounded and
  recursion too, so each program ends. And **prints inside
  expressions**, so that the order of evaluation shows in the output.
  That is what found ocaml-light's arm64 `ocamlopt` evaluating a `let`
  twice: `(let v = (print_string "x"; 0) in fun y -> v) 5` prints `xx`
  (`plan_ml.md`).

## 4. Shape the input so that the program must choose

Uniformly random input mostly exercises the easy path. The good
generators aim at the places where the implementation has a decision
to make:

- `diff_fuzz.py`: files of **few distinct lines**, so that the longest
  common subsequence has several answers and the two diffs must pick
  the same one; a last line without its newline; blanks, for `-b` and
  `-w`; now and then a NUL, for the binary check.
- `database/tests/fuzz.py`: rows enough to **split pages and roots**,
  indexes made before *or* after the rows, and every query shape chidb
  compiles, plus some it refuses.
- `editor/tests/fuzz.py`: every command, and the whole regexp notation.

## 5. What each side rejects is information too

When the reference refuses an input, skip it: the generator went
outside the subset. When only the twin refuses it, that is a **gap**;
when both accept and differ, a **bug**. `linker/tests/fuzz.py` sorts
its failures into these three, and keeps each one in the work
directory.

## 6. Seeds, and keeping what failed

Every fuzzer takes a count and a seed (`fuzz.py 7 500 13`). A failure
is reproducible by its seed, and several seeds are run before trusting
a change (`plan_redesign.md`: "run several seeds"). The failing input
is kept (`/tmp/mini-chidb-fuzz-SEED-N`, the linker's work directory),
not just reported.

## 7. Check the oracle: the reference can be wrong

A differential failure says the two differ, not which one is wrong.
Before debugging the twin, check the reference. Real cases:

- **The reference compiler's optimizer.** Optimized 7c gets some
  negative 64-bit constants wrong (`plan_bugs_goken.md`, 5b), so
  TinyC's reference is `7c -O0`.
- **The reference's libc.** Building `-simple`'s reference as goken's
  `7c -O0` libc plus 7l, the TinyC tests printed `%d%` and `%s%` where a
  number or a string belonged, and some random programs died on an
  illegal instruction. `-simple`'s output was the right one. The fix
  was a different reference: `TinyC_test.sh`'s own, the program by
  `7c -O0 -S` and libc by optimized 7c, both assembled by
  TinyAssembler. On `hello_libc`, goken's `-O0` build printed garbage
  for `args` and `pipe` and crashed on `stat` where `-simple` printed
  the right lines.
- **The reference's compiler, twice**: the database fuzzer found a
  miscompilation in OCaml's own arm64 native code (4.11 to 5.3, a
  stale derived pointer after a minor GC, `plan_bugs_ocaml.md`), and
  TinyML's found ocaml-light's `let` evaluated twice (3 above).

So a differential harness should make it cheap to look at *both*
outputs, and a reference's bug goes into a `plan_bugs_*.md`, with the
workaround.

## 8. Test the tests: mutate the program

A fuzzer that passes proves little until it has been seen to fail. So
break the program on purpose and check the fuzzer notices: in TinyC's
back end, a `<=` made `<` fails 4 of 30 random programs; a division
step skipped fails `udiv.c` (`plan_cc.md`). A mutation that nothing
catches is a finding too: it showed that `__udivmod`'s carry case
cannot happen (after k steps the remainder is below 2^k), and the code
was removed. The type checker's tests do the same by hand: an argument
swapped, a constructor's argument dropped, a `ref` made polymorphic,
each must be rejected where ocaml-light rejects it (`plan_ml.md`).

## 9. Stress an invariant with a knob

Some bugs only show when a rare event is frequent. mini-ml's collector
must find every live value; a program that allocates little never
collects. So every test runs again with `ML_HEAP=64`, a heap so small
that it collects at almost every allocation: a value left outside the
value stack then shows at once. This is fuzzing the *environment*
rather than the input, and it combines with the random programs
(`TinyML_test.sh` runs both).

## 10. Reduce the failing input, one statement at a time

A random program that fails is 40 lines of noise around one bad line.
Cut it down before reading any code. For `-simple`'s `fuzz13.c`
(2026-09-26), a small script kept the first k statements of `main`,
for k = 1, 2, ..., and ran each through the differential test; the
first failing k named the statement, `x2 = ((x4 || 255) - -1)`. From
there it was one short program: `||` with a constant side never jumps
to its "false" label, and the code generator took the stack's depth at
that label from the dead code before it.

The pitfall, from the same session: the harness cached the
reference's output **by file name**, and the reduction wrote every
candidate to the same `b.c`, so every step was compared with the first
step's reference, and the bisection pointed at an innocent line. Give
each candidate its own name (`b22.c`, `b23.c`...), or key the cache by
content.

## 11. Bisect across a build: swap the halves

When a program fails and the program is not the suspect, bisect which
*compiled unit* is. With two compilers whose objects link together,
cross them: `alarm.c` compiled by `-simple`, linked with the libc of
the byte-identical back end, ran correctly, so the bug was in libc as
`-simple` compiled it. Then a libc made of compat's objects with only
some of `-simple`'s swapped in (by directory: `port_*` fine, `os_*`
hangs; then file by file) named `os_linux_notify.7` in a dozen runs.
Its `signotify` switches on `setjmp`: the switch's temporary address
was pushed before the call, spilled across it, and after `longjmp` the
reload read a spill slot that a later call had reused. 7c never has
anything live across a call there (Sethi-Ullman computes the call
first), so `-simple` now computes a call's value before the address it
is stored to.

Whatever is made of interchangeable halves (objects in an archive,
modules of two builds) can be bisected by swapping them, without
reading a line of the code first.

## 12. Harness hygiene

A differential harness runs thousands of untrusted programs; its own
failures look like the programs'.

- **Kill for real.** `timeout 10` sends SIGTERM, and a program that
  installs signal handlers (`alarm.c`, `notify.c`: libc's notes catch
  SIGTERM) can ignore it: a hung `-simple` build of `alarm` blocked
  `libc.sh` for twenty minutes. Use `timeout -k 2 10`, SIGKILL two
  seconds after.
- **Same name, same argv[0].** A program that prints `argv[0]`
  (`TinyC_tests/ptr.c`) differs if the two executables have different
  paths. Copy each to the same name in two directories and run it as
  `./name` from there, as `TinyC_test.sh` does.
- **Same inputs everywhere else too**: the same current directory, the
  same arguments (`one two`), for both runs.
- **A "differs" between identical executables is noise.** When
  `elfcmp.py` says the two executables are the same and the runs still
  differ, the difference is in the environment (timing, signals),
  not in what was built; rerun before debugging.
- **Kill by PID, not by pattern**: `pkill -f "tests/libc.sh"` also
  matched the shell running the pkill (its command line contains the
  pattern), which killed it. (Also in `notes_debugging_techniques.md`,
  technique 10.)
