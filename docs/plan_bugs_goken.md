# Bugs found in goken, from ix

What building ix against goken (`~/goken`) turned up: bugs in goken's
toolchain, in its sources, and behaviour that makes its output depend
on the host; and, for mk, rc, ed and sam, bugs in principia's C and in
the references ix tested those against (9base and plan9port, as Debian
packages them). None is fixed in goken; each is for the author to decide
(goken may be modified). ix reproduces goken's output where the output
is the contract (the listings, the executables' bytes), and says so in
its code where it does. Found 2026-09-23 and 24, while building
mini-mk, mini-rc, mini-ed, mini-asm, mini-ld and mini-cc. Bugs in xix
are in [`plan_bugs_xix.md`](plan_bugs_xix.md).

Each entry: what, the evidence and how to reproduce it, what ix does.

## The linkers

### 1. 5l and 7l write the ELF section table inside the data

The section headers go at HEADR+text+data, which is inside the data's
last page, so when the data is large they overwrite its end. The
executable then misbehaves:

- arm, `5c -O0`: goken's `pipe` prints garbage (`^@^@^@^A...`) where
  ix's prints `hello pipe` / `pipe ok`; with `5c` (optimized), goken's
  `dirread` fails (patched with ix's bytes, it passes).
- arm64, `7c -O0`: goken's `args` prints `argv[1]=%s%` for `one`,
  `notify` and `utfmisc` exit 1 without output; `dirread` fails too
  with `7c`.

The bytes are otherwise the same as ix's. Reproduce:
`MINICC=1 linker/tests/libc.sh 5 /tmp/w ~/goken/tests/c/hello_libc/*.c`
(and 7): the lines "SAME but the section table ... RUNS DIFFERENTLY".
ix: mini-ld puts the table after the data; `linker/tests/elfcmp.py`
compares everything else. Fix: place the table after the data, or
page-align it.

### 2. 5l's `immrot` computes in a 64-bit `ulong`

The rotation that decides whether a constant is an immediate runs in
the host's 64-bit `ulong`, so only 0..255 are found immediate:
`$0x400` goes to a literal pool. The code is correct, but longer.
ix: mini-ld does the same, with a `rotate` flag for the real rule
(`linker/Arm.ml`).

### 3. 7l's logical immediates leave out the element size

Below 64 bits, the bitmask encoding drops the element size of the
pattern (known: xix's `docs/claude_notes/arm64_port.md`). ix: mini-ld
reproduces it (`linker/Arm64.ml`, case 53).

### 4. 7l -H6 fails on the darwin libc

`GOOS=darwin H=-H6 linker/tests/libc.sh 7 ...`: 7l itself fails on
`alarm` and `notify`, with redefinitions in the darwin libc.

## The compilers

### 5. 7c -O0 generates code that crashes: `mem` and `stat` on arm64

With `7c -O0`, the hello_libc programs `mem` (segmentation fault) and
`stat` (illegal instruction) crash. mini-cc's executables are the same
bytes and crash the same way; on arm (`5c -O0`) both run. `mem` also
crashed in goken's own optimized build (`plans/plan_asm.md`, mini-ld's
milestone 2 on arm64). Not investigated yet:
the bug is in 7c's code generator or in libc's C that only `-O0`
exposes. Reproduce: `MINICC=1 linker/tests/libc.sh 7 /tmp/w
~/goken/tests/c/hello_libc/*.c` (exit 139 and 132).

### 5b. 7c's optimizer loads a negative 64-bit constant with MOVW

`long long x; x = -(2147483647);` (or `x = -2147483647;`): optimized
7c emits `MOVW $-2147483647,R9` then `MOV R9,x+0(SB)`. A MOVW writes
the 32-bit register and zeroes the upper half, so `x` is 2147483649.
`7c -O0` emits `MOV $-2147483647,R1`, correct. Found by TinyC's
fuzzer (`tiny/TinyC_fuzz.py`), whose reference is now `7c -O0`.

### 5c. `double op float` is computed in float

cck's table of the usual arithmetic conversions (`sub.c`'s `tab`, the
row of TDOUBLE) gives TFLOAT for a double and a float, while a float
and a double give TDOUBLE. So `d * f` loses the double's precision:
7c -O0 on `r1 = d * f; r2 = f * d;` emits `FCVTDS F0,F0` and `FMULS`
for the first, `FCVTSD` and `FMULD` for the second. Probably a typo
in the table. mini-cc reproduces it (`compiler/Tree.ml`'s
`arith_tab`, which says so).

### 5d. A narrowing cast tested as a condition is not narrowed

`short x = -256; if((uchar)x) ...` is taken: 5c and 7c, at -O0 as
optimized, load the short (`MOVH`) and compare all of it with 0,
while `(uchar)-256` is 0 (gcc agrees). The narrowing between two
registers (txt.c's `gmove`, short to uchar) is a plain move, the
truncation left to a store; in a condition nothing is stored. Found by
TinyC's fuzzer (fuzz44 of `tiny/TinyC_fuzz.py`, seed 11: `x0 ^=
(uchar)((uchar)x3 ? 256 ^ x2 : x5)`), where TinyC is right and 7c the
reference. mini-cc reproduces it, being 7c's twin.

### 6. The code depends on the host's `qsort`

cck's reassociation (`scon.c`'s `acom2`) sorts its terms with `qsort`,
and its comparators (`acomcmp1`, `acomcmp2`) break ties on the
elements' addresses. So which of two equal terms comes first depends
on how the host's `qsort` moves elements. goken links 5c and 7c with
glibc's, a merge sort, which reverses equal terms at each sort; Plan
9's own `qsort` (libc/port/qsort.c, a quicksort) gives other orders,
worked through by hand on `f.txtsz+f.datsz+f.bsssz` in `utilities/kernel/ksize.c`.
The same source may compile to different code on another host (macOS,
Plan 9). ix: Check's `acom2` reproduces the merge sort, and says why.
Fix: break ties on an index kept in the term.

### 7. `nodv2uh` calls `_v2ul`

In cck's `com64.c`, `nodv2uh = fvn("_v2ul", TUSHORT)`: a vlong cast to
`ushort` calls `_v2ul`, like a cast to `ulong`, while every other
conversion has its own function. Probably a typo for `_v2uh`; the
result isn't truncated to 16 bits by the call. Only 5c uses these
calls. ix: the same (`compiler/Gen.ml`, `of_v`). Not checked at run
time.

### 8. The multiply table's cache and 0

`mul.c`'s `mulcon0` looks in a cache of 20 entries, all zero at the
start, so `mulcon0(0)` finds "no program" there; once 20 other
constants have replaced them, 0 is searched for instead. What `x * 0`
compiles to could then depend on the constants before it in the file.
Latent: not seen in the corpus. ix:
`Multiply.mulcon0 0` is always "no program". Also, 5ck's `mul.c`
computes in the host's `long` (64 bits), 7c's in `int32`.

### 9. 5ck's listing loses float constants

5ck (and cck's other back ends) print a float constant with `%e`, six
digits: `$4.294967e+09`, so a `5ck -S` listing doesn't reassemble to
the same object. Principia's 5c prints `%.17e` (with Plan 9's fmt,
the fewest digits that read back, then zeros). ix: mini-cc prints as
principia's 5c (`compiler/Emit.ml`, `e17`).

### 10. cck's `-x` dump: runes and offsets

`prtree` prints an `L"..."` string with `%S` on 4-byte runes, which
comes out as `"\072\z\z\z..."`, and an offset as an unsigned 32-bit
number (`4294967288` for `-8`). Debug output only.
`compiler/tests/strip_x.py` normalized the first, while mini-cc's `-x`
printed 5c's trees (until 2026-09-24, when the trees became an OCaml
ADT and `-x` its own dump; the script is in the history).

## The sources

### 11. hoc: `EQ` is a macro and an enumerator

`utilities/calc/hoc`: the grammar's tokens are `#define`d (`EQ` among
them) before `y.tab.c` includes `libc.h`, whose `base/ord.h` has
`enum { EQ = 0, ...}`. 5c and 7c fail with a syntax error:
`printf '#define EQ 1\n#include <u.h>\n#include <libc.h>\n' > h.c;
5c -I$HOME/goken/include -I$HOME/goken/include/ALL
-I$HOME/goken/include/arch/arm h.c`.

### 12. grep: `literal` is `int` and `bool`

`utilities/text/grep`: `grep.h` declares `extern int literal;` and
`globals.c` defines `bool literal;` (a `u8`). 5c reports "external
redeclaration of: literal", prints its listing anyway, and exits 1.

### 13. awk and diff don't compile with their mkfiles

`utilities/text/awk` and `utilities/compare/diff` include `ctype.h`
and `stdio.h`, which are only under `include/APE`, and their mkfiles
don't add it. Known: `utilities/mkfile` has them commented out
("TODO: awk must be relpized after the removal use of APE in it").

## mk, rc, ed and sam: principia's C, 9base, plan9port

From the differential tests of mini-mk, mini-rc and mini-ed (their
plans' Status sections: `plans/plan_mk.md`, `plan_rc.md`,
`plan_ed.md`).

### 14. principia's mk loses a `:R:` rule's arcs

principia's refactored `graph.c` drops the arcs of a regular-expression
rule; 9base's does not, and mini-mk follows 9base.

### 15. mk swallows a `}` after an unbraced name

`shprint.c`'s `vexpand()`, printing a recipe: `{cmd $X}` prints
without its `}` (9base's mk). mini-mk prints the same, as its tests
compare the printed lines.

### 16. mk exports an empty variable as one empty word

`SYSLIBS=` reaches rc as `SYSLIBS=`, which plan9port's rc reads as one
empty word (`$#E` is 1), so `ocamlc $SYSLIBS` gets an empty argument
and fails: found building xix's `generators/lex/`. On Plan 9 an empty
`/env` file is `()`. omk skips empty variables (its comment says its
author met this with plan9port's mk); mini-mk doesn't export them, a
documented difference (`empty_rc`).

### 17. mk(1) is wrong about command-line assignments

The man page says a command-line `CC=z` overrides "the first (but not
any subsequent)" assignment; mk overrides every assignment to `CC`
(checked on plan9port's mk; omk agrees with the program).

### 18. libregexp takes an overflowed thread list for a match

`regaux.c` and `rregexec.c`: an OR's dedup looks only at the threads
not yet run (it passes its own place, `tlp`, not the list's start: the
"optimization" its comment calls a bug), so a loop that can match empty
adds the same instruction until the list of 10 overflows, then the one
of 50; `rregexec` returns -1, which ed takes for a match. `((x?)?)*` on
`xxb` matches the empty string. When the list overflows before any
match, 9base's ed segfaults (exit -11, dosub reading a null pointer).
mini-ed reproduces the lists, sizes and all.

### 19. 9base's sam: character classes, and a stray `d`

`[a-c]` matches only `a` and `c`, `[^ab]` a newline; and it prints a
`d` after its numbers (plan9port's `%lud`). TinyEditor's tests use no
class, and take the `d` out.

### 20. 9base's rc ignores SIGTERM

`timeout` can't stop it; the harness uses `timeout -s KILL`.

### 21. 9base's rc: a missing program ending a subshell leaves status 0

The last command of a subshell is exec'ed without a fork, so a missing
program there leaves `$status` 0 where rc means 1 (an artifact of the
optimization; mini-rc keeps 1, a documented difference). And in a
pipe, a missing program's stage exits with the `$status` it inherited
(`scsicodes`; not copied).

### 22. principia's mkenam scripts name a moved path

`compilers/5c/mkenam` names `include/obj/5.out.h` by a path that moved;
`8c/mkenam` no longer fits its header, and both eds fail on it alike.

## How they were found

The runners that compare ix with its reference, case by case or file
by file: mini-mk's, mini-rc's and mini-ed's `differential.sh` and
fuzzers, against 9base; `compiler/tests/front.sh` (trees, while they were 5c's),
`compiler/tests/listing.sh` (listings), `linker/tests/libc.sh`
(executables, and running them) and `linker/tests/fuzz.py`, against
goken; `tiny/TinyC_fuzz.py`, against 7c; and reading the C while
porting it.
