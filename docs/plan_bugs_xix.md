# Bugs found in xix, from ix

ix builds each program as a twin of a Principia program, tested
against a reference, and reads xix (`~/github/xix`) as the earlier OCaml
port. Its differential tests ran xix's omk and orc beside 9base's mk
and rc (TinyMk's and TinyRc's phases, 2026-09-23): what they found is
below. For the toolchain, ix's tests have not run xix's programs yet,
only read their code: that part lists what goken's output depends on
and xix doesn't do yet. Bugs in goken, principia's C, 9base and
plan9port are in [`plan_bugs_goken.md`](plan_bugs_goken.md).

## omk (xix's `builder/`)

From `builder/tests/differential.sh live`, and `-n` over xix's
directories (`plans/plan_mk.md`, phases 1 to 7):

### 1. `$X.o` on a list is refused

With `X=a b`, mk gives the two words `a b.o`; omk stops with "use of
list variable 'X' in scalar context".

### 2. A recipe that leaves its target untouched is an error

`cmp -s new old || mv new old` regenerates a header without changing
it, and mk then rebuilds nothing that depends on it (its `update()`
re-stats the target: early cutoff by mtimes). omk stops with "recipe
did not update config.h".

### 3. `prog.mk` hangs omk

omk has no `:P:`, and the corpus case `prog.mk` ran until the harness's
timeout, added for it.

### 4. The agreement, and the speed

omk agrees with 9base's mk on 2 of the 32 corpus cases (after
stripping its `|recipe|` markers and its colours); most differences
are messages and its parallel default, the ones above are semantics.
`-n` over xix's 73 directories: 21 identical to 9base's, and 11.35 s,
against 1.56 s for 9base's mk and 1.94 s for TinyMk. (omk does skip
an empty variable when exporting to rc, which 9base's mk does not:
there omk is right, `plan_bugs_goken.md`, 16.)

## orc (xix's `shell/`)

From `plans/plan_rc.md` (checked 2026-09-23):

### 5. `$x(2)` prints `a b c 2`

A subscript is taken as a word to concatenate: with `x=(a b c)`,
`echo $x(2)` prints `a b c 2` where rc prints `b`.

### 6. `$"x` and `^` on a variable aren't compiled

A 17-line script of the most common rc stops at "TODO compile:
Stringify" (`$"x`) and "TODO compile: Concat" (`$x^y`). Functions
aren't exported (`fn#f=`: orc's Prelude lists it as missing), and orc
runs only given its rcmain (`-m shell/data/rcmain-unix`). With it, 4
of the 36 corpus cases agree with 9base's rc.

## The linker (xix's `linker/`)

### 7. No `follow`: xix's executables can't be 5l's, byte for byte

5l and 7l reorder the code in the order its flow goes (`pass.c`'s
`follow` and `xfol`): a B to code not yet placed pulls that code in,
a conditional branch is inverted when that makes its target the next
instruction, up to four instructions are copied instead of branching
back, and what the flow never reaches is dropped. xix has no such
pass (`grep follow linker/*.ml`), so its layout is the objects'
order. ix's TinyLd has it (`Link.follow`), and needs it to be the
same as 5l on goken's libc.

### 8. NOPs: xix drops them as 5l does

5c at `-O0` leaves NOPs (`NOP R0`, `NOP F0` before a return), which
5l and 7l remove (`noop.c`), moving a branch to one to the next
instruction; `follow`'s four-instruction lookahead doesn't count them.
xix removes them too (`Rewritei.ml`, `Rewritev.ml`,
`find_first_no_nop_node`). Not a bug: noted because TinyLd had missed
it (ix's libc builds were from optimized 5c until tinycc).

## The compiler (xix's `compiler/`)

### 9. What 5c's code depends on that occ doesn't do yet

xix's occ aims at 5c's code (its comments cross-reference 5c's
functions), and its Codegen is started (its TODO: fields and
structures, float, other integer types, alignment). For its code to
be 5c's byte for byte, as ix's tinycc is, it will need:

- **the reassociation** (cck's `acom`): `a + b + c` and `p->base + len
  - 1` are regrouped by multiplier, which changes the evaluation
  order and the registers. occ has none (`grep acom compiler/*.ml`).
  And its sort must reproduce glibc's merge sort on ties
  (`plan_bugs_goken.md`, 6).
- **Plan 9's `%.17e`** for float constants, if its listings are to be
  compared (`plan_bugs_goken.md`, 9).
- **`#pragma profile`**, which sets TEXT's flag (libc's `vlrt.c`).
- **the round robin of registers** (`regalloc`'s `lasti`, modulo 5):
  every listing depends on it.

### 10. 7l's bitmask bug is documented in xix

xix's `docs/claude_notes/arm64_port.md` describes 7l's logical
immediates that leave out the element size below 64 bits; ix's TinyLd
reproduces it (`plan_bugs_goken.md`, 3).

## To do

Run xix's `occ`, `5a`/`5l` and `7l` over the same corpus runners
(`compiler/tests/listing.sh`, `linker/tests/libc.sh`) to find its
actual bugs, rather than its gaps.
