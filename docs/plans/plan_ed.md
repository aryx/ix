# Plan: TinyEd, a text editor from scratch, for teaching (`editor/`)

Companions:
[`notes_ed.md`](../tutorials/notes_ed.md), the tutorial: a buffer of
lines, addresses, the command loop, regular expressions and how they
are matched, substitution, `g`, and the files. And
[`notes_ed_related_work.md`](../related-work/notes_ed_related_work.md):
from QED to ed, sed and grep, ex and vi, Emacs, sam and acme, and the
regular expression engines. The twins are the Principia book
`editors/ed.nw` (ed in C: `ed/ed.c`, 2,121 lines, plus the 1,479 of
`lib_strings/libregexp`) and xix's `editor/` (oed, 1,794 lines of
OCaml, `.ml`, `.mli` and `.mll`, with its regular expressions from
the `re` library).

The third ix program, after TinyMk ([`plan_mk.md`](plan_mk.md)) and
TinyRc ([`plan_rc.md`](plan_rc.md)), planned the same way; the
principles are in [`../README.md`](../README.md). This time the author
asked for the whole of it at once, the documents, TinyEd and the free
variant, to review at the end ("go for ed, but don't wait for my
review, do also the implementation the TinyEditor.ml final step
too").

## Context

ed is Ken Thompson's editor (Unix V1, 1971, after his QED), and the
editor the other Unix tools grew from: `g/re/p` is grep, the `s`
command is sed's, and vi began as the visual mode of ex, an extended
ed. It edits a *buffer* of lines with commands read from standard
input, one per line, each with up to two addresses. So it is
scriptable, and that is still what it is used for: principia builds
its assemblers' opcode tables with ed scripts
(`compilers/5c/mkenam`), and `diff -e` prints the ed script that turns
one file into another.

Why ed third:

- **A reference runs today**: 9base's ed, `/usr/lib/plan9/bin/ed`,
  and its behaviour is principia's `ed.c` (checked: `l` prints
  `\x00e9`, as principia's code does and plan9port's current code does
  not). So the corpus method of TinyMk and TinyRc carries over.
- **It teaches what the first two did not.** mk was a graph and rc was
  processes. ed is a data structure (lines, with an identity marks can
  hold) and an algorithm: regular expression matching, which is where
  the tiny version can be most unlike the C (decision 2).
- **xix's twin is partial.** oed has no `s///g`, no `\1` or `&`, no
  marks, no `g` (the TODOs in `Commands.ml`, `Address.ml`), and its
  regular expressions are the `re` library's, not Plan 9's. So, as
  with rc, TinyEd can be both smaller than the C and more complete
  than oed.

## Principles

Those of [`../README.md`](../README.md), and three of its own:

- **The program is ed.c and the binary is 9base's.** The man page says
  a NUL is discarded; the code cuts the line there (a C string ends at
  its first 0), and TinyEd follows the code, with a case. Where the
  code and the binary disagree, the binary wins, since it is what the
  corpus is recorded from.
- **Scripts are the inputs, and they are few.** Unlike rc, ed has no
  corpus of scripts in principia: two `mkenam`s. So the corpus is
  written from the man page and the code, one case per command and
  per quirk, and the real inputs are generated: `diff -e` over xix's
  history (milestone 2).
- **Unicode is kept, because it is nearly free.** The buffer holds
  UTF-8 bytes; only the matcher and `l` need to know where a character
  ends, and OCaml 4.14 decodes it (`String.get_utf_8_uchar`). That is a
  few lines, so the rule of the README (drop it unless it is as
  compact) keeps it.

## The interface: ed's, unchanged

`ed [-] [-o] [file]`; every command of ed.c:

| command | what | TinyEd |
|---|---|---|
| `a` `i` `c` | append, insert, change: text until a line `.` | kept |
| `d` | delete | kept |
| `p` `P` `l` `n`, and a `p`/`l`/`n` suffix | print, list (escaped, folded), number | kept |
| newline, `=` | print the next line; print a line number | kept |
| `s/re/rhs/` `g`, `sN`, `&`, `\1`-`\9`, `\` newline | substitute | kept |
| `g/re/cmds` `v/re/cmds` | global: mark, then run the list on each | kept (and `g/re/d` in one pass) |
| `m` `t` `j` | move, transfer (copy), join | kept |
| `k`x, `'`x | mark a line, address it | kept |
| `u` | undo the last `s` | kept |
| `r` `w` `W` `e` `E` `f` `q` `Q` `wq` | files and quitting | kept |
| `b` | browse, a page at a time | kept |
| `!` | a shell command, by `rc -c` | kept (the `rc` of `$PATH`, as 9base) |
| addresses: `.` `$` `n` `/re/` `?re?` `'x` `+` `-` `^` `,` `;` | | kept |
| interrupt, hangup | `?` and back to commands; the buffer saved in `ed.hup` | kept |
| the temp file and its limits: 4,096-rune lines, 128-byte names, 256-byte `g` lists and patterns | | dropped: the buffer is in memory, with no limits (a deliberate difference, with a case) |

Nothing else is dropped: every command is a few lines once the
addresses and the buffer exist. The names: `tinyed`, and the directory
`editor/`, xix's (principia's is `editors/`).

## Target layout

```
editor/                  library ix_ed + the tinyed executable
  Regex.ml(i)            Plan 9's notation to a tree; leftmost-longest
                         matching with submatches (decision 2)
  Text.ml(i)             the buffer: lines with an identity, dot, dol,
                         marks, the undo pair (decision 1)
  Input.ml(i)            the command stream: stdin a byte at a time,
                         one character of pushback, g's list (decision 3)
  Out.ml(i)              printing: l's escapes and folding, n's numbers,
                         standard output or error (-o)
  Address.ml(i)          addresses and ranges, and their defaults
  Command.ml(i)          the loop, every command, g, errors, quitting
  CLI.ml(i), Main.ml     flags, the file argument, signals
editor/tests/            Testo: the .mli examples, the laws, the corpus
editor/tests/corpus/     scripts, each with its output and files
                         recorded from 9base's ed
editor/tiny/             TinyEditor.ml (see "Outside ed")
```

**The size target**, set by module as TinyRc's was: Regex 220, Text
100, Input 60, Out 60, Address 120, Command 380, CLI 60, Main 10:
about **1,000 lines of `.ml`**, a third of the C ed with the parts of
libregexp it uses, and a little over half of oed, while doing what oed
doesn't. TinyRc came out 6% over its per-module target; the Status
will compare.

## Groundwork decisions

### 1. The buffer is an array of lines in memory, each with an identity

ed.c keeps the text in a temporary file and the buffer as an array of
offsets into it (`zero[]`), one per line, and it steals the low bit
of each offset: `g` marks the lines it will visit with it, and `k`
names a line by its offset, so a mark follows its line through a
move. The temporary file was 1971's answer to a small memory.

TinyEd keeps a growable array of lines, each a record with its text
and a mutable `global` flag. A line's **identity is the record**:
`k` stores the record, `'x` finds it by physical equality (`==`), and
a line that is deleted takes its marks with it, as in ed.c. `s`
makes a new record, moves the marks that pointed to the old one, and
keeps the pair (old, new) for `u`. That is ed.c's design with the
file taken out, and it removes `getblock`, `blkio`, `putline`'s
offset arithmetic, and the `TMP` error: some 250 lines of the C.

### 2. Regular expressions: backtracking with a memo, which is the Pike VM

**Changed in phase 1** (see the Status): the claim below, that the
memoized backtracker gives libregexp's answers, is true of a Pike VM
that keeps its threads in priority order, and false of libregexp,
whose thread order is not a priority. The fuzzer found it; TinyEd now
runs libregexp's own algorithm, and the backtracker is TinyEditor.ml's.
The text is kept as it was planned.

The notation is Plan 9's (regexp(7)): egrep's, before egrep got
complicated. `.`, `[...]` and `[^...]`, `^` and `$`, `*` `+` `?`, `|`,
and `(...)`, which both groups and captures (no backslashes), with a
`\` before any metacharacter or the delimiter to quote it. The
matching is **leftmost-longest** (checked on 9base: `s/o|on/X/` on
`one` gives `Xe`), and the submatches are those of the
highest-priority path among the longest (`(o|on)(e|ne)*` on `one`
gives `\1` = `o`, `\2` = `ne`).

libregexp compiles to instructions and runs them as a Thompson NFA with
submatches, a thread list per character (the "Pike VM", from Rob Pike's
sam; the name is Russ Cox's). TinyEd does something that looks
different and is the same: it **matches by backtracking over the
tree**, trying the alternatives in priority order (left before right,
greedy before lazy), keeping the longest end found and the captures of
the first path to reach it; and it **remembers every (node, position)
pair it has already tried**. A second visit to a pair can only find
ends already found, by a path of lower priority, so it is cut. That is
exactly the Pike VM's rule (a thread that reaches an instruction
another thread holds at the same character is dropped), so the answers
are the same, and so is the cost: at most nodes x positions steps per
start, never the exponential blowup of a naive backtracker. About 150
lines instead of regcomp's 663 and regexec's 242, and no instruction
set to explain.

**Unicode**: positions are byte offsets into the line; a step over a
character decodes one UTF-8 sequence. `s`, `&` and `\1` work on bytes,
so nothing else changes.

**What to watch**: the empty match in `s/x*/-/g` (`-a-b-c-`,
checked); `^` in `s/^/>/g`; a `\n` naming a group that did not match
(an error on 9base, checked); the class `[^...]`, which never matches
a newline (there are none in a line, so it can't show).

### 3. Commands read their own arguments, as they go

ed.c has no parser: `commands()` reads an address, a character, and
each command reads the rest of its line itself -- a file name, a
pattern, the text of `a` until `.`, an `s` whose replacement goes on
past a `\` newline. TinyEd keeps that shape, because the alternative
(parse a command, then run it) fails three ways: addresses do things
while they are read (`;` sets dot before the next address, `/re/`
becomes the remembered pattern), the text of `a` comes from the same
stream as the commands, and `g` runs its command list once per line,
reading it again each time, with dot changed. So there is an input
(`Input`): standard input read a byte at a time, as plan9port does it,
so that a `!` command's child reads what ed has not; one character of
pushback (`peekc`); and, while `g` runs, its list as a string in front
of it (`globp`).

### 4. Errors are an exception, with ed.c's clean-up

`?`, or `?file` for a file that can't be opened, on standard output,
and back to the command loop: an exception caught by the loop instead
of `setjmp`/`longjmp`. The clean-up is ed.c's, and one part of it is
visible: **after an error, if standard input is a file, the rest of it
is skipped** (ed.c seeks it to its end). So a script run as `ed f <
script` stops at its first error, and the same script through a pipe
goes on (checked on 9base, both). `q` with unsaved changes is an
error once, and quits the second time. With `-`, it never is.

### 5. Output is standard output, a line at a time

Everything goes to standard output, even the `?`s, and to standard
error with `-o` (so that `w` can write the buffer to standard
output). ed.c buffers a line of 70 bytes and writes it at each
newline; TinyEd writes each line whole. `l` folds at column 64,
continuing with `\`, a newline and a tab, and prints a character
outside the printable ASCII as `\x` and four hex digits; a line that
ends with a blank gets a `\n` after it.

### 6. No temp file, no limits

The buffer lives in memory; there is no `/tmp/eXXXXXX`, no line longer
than 4,096 runes is refused, and no file name longer than 128 bytes.
A deliberate difference, with one case and a `.tiny.out`: a line of
5,000 characters.

## Outside ed: TinyEditor.ml

TinyBuildSystem.ml dropped mk's syntax, and TinyShell.ml kept rc's
core. `editor/tiny/TinyEditor.ml` goes further from its twin, because
there is a better core to keep: **sam's command language**, Rob
Pike's rethinking of ed ("The Text Editor sam", 1987, and "Structural
Regular Expressions", 1987). There, the buffer is one string, not
lines; dot is a range of characters; an address is a range (`#n` a
character, `n` a line, `/re/` a match, `a,b` from one to the other);
and the loop is a command, `x/re/cmd`, that runs cmd on each match in
dot, so that `,x/foo/c/bar/` is ed's `g` and `s` in one idea, and
lines are just one structure among others (`,x/.*\n/` is "each line").
`y`, `g`, `v`, `{...}`, `a` `i` `c` `d` `s` `p` `=` `m` `t`, `r` `w`
`e` `q`: about twenty commands, all on ranges.

It is one file, with its own smaller matcher (leftmost-longest is
kept, since sam has it too), and it has a runnable reference: 9base
ships `sam`, whose `-d` mode reads commands without a terminal
(checked: `,x/o/c/0/` then `,p` works). So its test is TinyEd's
method, against `sam -d`. The question it answers: is an editor's
core ed's lines, or sam's ranges? The target: about 450 lines.

## The modules, with their references

The ideas are in [`notes_ed.md`](../tutorials/notes_ed.md); the
sources (from memory where not linked, to check when each `.mli` is
written):

- **Regex** (§4): regexp(7); principia's `lib_strings/libregexp`
  (`regcomp.c`, `regexec.c`, `regaux.c`); Ken Thompson, "Regular
  Expression Search Algorithm" (CACM, 1968); Russ Cox, "Regular
  Expression Matching Can Be Simple And Fast" (2007) and "Regular
  Expression Matching: the Virtual Machine Approach" (2009).
- **Text** (§2): ed.c's `append`, `rdelete`, `gdelete`, `move` and
  `reverse`, `join`.
- **Input**, **Command** (§3, §5-§7): ed.c's `commands`, `getchr`,
  `gettty`, `global`, `substitute`, `compsub`, `dosub`, `error_1`.
- **Address** (§3): ed.c's `address`, `setwide`, `squeeze`.
- **Out** (§8): ed.c's `putchr`, `putd`, `printcom`.
- **CLI**: ed.c's `main`, `notifyf`, `rescue`, `quit`.
- For TinyEditor.ml: Rob Pike, "The Text Editor sam" (Software
  Practice and Experience, 1987); "Structural Regular Expressions"
  (EUUG, 1987); sam(1).

## Tests (what the program is for)

- **The corpus**, `editor/tests/corpus/`: a case is a script
  (`case.ed`) and optionally a file to edit (`case.txt`), run as `ed
  case.txt < case.ed` in a fresh directory; recorded are stdout and
  stderr, the exit status, and every file in the directory after, all
  from 9base's ed. One case per command and per quirk of this plan.
- **The laws**: `diff -e a b`, then `w`, turns `a` into `b`; `s` then
  `u` leaves the buffer as it was; `m` there and `m` back is the
  identity; `t` then `d` of the copy too; `g/re/p` prints what
  `grep` prints; `w` then `e` of the same file leaves the buffer and
  prints the same count.
- **Milestone 1: principia's `mkenam`s.** `compilers/5c/mkenam` and
  `8c/mkenam` on their headers: the same `enam.c` as 9base's ed.
- **Milestone 2: xix's history, replayed.** For every `.ml` file
  changed in the last 300 commits of xix, `diff -e old new` run by
  TinyEd on `old`: the result is `new`, and TinyEd's output (the
  counts) is 9base's.
- **Milestone 3: a session**, through a pipe, as a person would type
  it: `a`, text, `.`, `p`, a mistake, `s`, `w`, `q`.

## Phasing

0. **Groundwork**: `editor/`'s dune, the corpus harness, the first
   cases recorded from 9base's ed (the checks of this plan's Status).
1. **Regex**: the notation, the matcher, and its laws (against
   9base's ed on a table of patterns and lines).
2. **Text, Input, Out, Address**: `p`, `n`, `l`, `=`, newline, every
   address form, `a` `i` `c` `d`, `r` `w` `W` `e` `E` `f` `q` `Q`.
3. **Command**: `s` in all its forms, `u`, `g` `v`, `m` `t` `j`, `k`,
   `b`, `!`, errors and their clean-up, `-` and `-o`, signals.
4. **The milestones**: `mkenam`, xix's history, the session; the line
   count.
5. **`editor/tiny/TinyEditor.ml`**, sam's language, against `sam -d`.
6. **Docs**: `notes_ed.md` checked against the code, the numbers
   filled in.

## Status

- **2026-09-23, the plan written**, with the tutorial and the related
  work, and the code started right after, as the author asked. Checked
  on 9base's ed first, for the plan and the tutorial:
  - matching is leftmost-longest (`s/o|on/X/` on `one`: `Xe`), and
    submatches follow priority among the longest (`(o|on)(e|ne)*` on
    `one`: `[o,ne]`); `(a*)(a*)` gives `[aaa,]`; a `\1` naming a group
    that did not match is `?`;
  - `s/x*/-/g` on `abc` gives `-a-b-c-`; `s2/a/X/` on `aaaa` gives
    `aXaa`, and `s2/a/Y/g` after it `aXYY`;
  - `l` prints a tab as `\t`, a backslash as `\\`, `\001` as `\x0001`
    and `é` as `\x00e9`; `.` matches `é` whole;
  - a file whose last line has no newline: `'\n' appended`, and the
    count includes it; a NUL cuts its line (`a\0b` reads as `a`);
  - an error in a script read from a file ends it; through a pipe the
    script goes on; `q` after a change is `?` once;
  - `g/x/a\` with the text on the next lines, the final `.` omitted,
    appends after each matching line;
  - `u` twice is `?`, and `u` on another line than the last `s`'s;
  - a `\` newline in a replacement splits the line;
  - `;p` alone prints the whole buffer, as `,p` does;
  - `k` marks follow their line through `m`.
  - `sam -d` runs without a terminal, for TinyEditor.ml's tests.

- **2026-09-23, phases 0-3 DONE: TinyEd.** `editor/`: Regex, Text,
  Input, Out, Address, Command, CLI; a corpus harness
  (`tests/differential.sh`, cases as `case.ed` with an optional
  `case.txt`, `case.args` and `case.pipe`). The first 38 cases, one
  per command and per check above, passed on the first run -- all of
  them, which made me check the harness (it did run tinyed). The
  numbers and the lessons:
  - **A fuzzer against 9base's ed** (random files, random scripts of
    every command, random patterns of the whole notation; a script in
    the scratchpad): 15 mismatches in 5,000 at first, all in the
    matcher, and each a lesson about libregexp, which is the
    specification here:
    - **Decision 2 was wrong.** `((x?)?)*` on `xxb` matches the empty
      string on 9base, `xx` with the memoized backtracker. The cause is
      in `regaux.c` and `rregexec.c`: an OR follows its left branch at
      once and puts its right branch at the *end* of the thread list,
      and the left of `*`, `+`, `?` is the skip (of `a|b`, the `b`) --
      so the list is not in priority order. And the dedup of an OR's
      branch only looks at the threads not yet run (it passes its own
      place, `tlp`, not the list's start: the "optimization" its
      comment calls a bug), so a loop that can match empty adds the
      same instruction again and again, until the list of 10 overflows,
      and then the one of 50; `rregexec` then returns -1, which ed
      takes for a match: the best found so far, here the empty one.
      TinyEd now compiles to regcomp's program and runs regexec's lists,
      sizes and all (Regex.ml: 307 lines, against 220 planned).
    - **regcomp's postfix operators don't apply left to right.** They
      go through its operator stack, with `*` < `+` < `?`, and an
      operator only pops those of higher or equal priority: so `x*+` is
      `(x+)*` and `b?+?` is `(b??)+`. Found on `(c?)*+`.
    - After both, 1 mismatch in 10,000, where 9base's ed segfaults
      (exit -11): the list overflows before any match, ed takes -1 for
      one, and dosub reads a null pointer.
  - **Milestone 1, principia's mkenams**: `compilers/5c/mkenam` on
    `include/obj/5.out.h` (the scripts name a path that moved) gives
    the same 93-line `enam.c` under both eds; `8c/mkenam` no longer
    fits its header, and both eds fail on it alike.
  - **Milestone 2, xix's history**: `history.sh` over the last 3,000
    commits of xix: **5,716 of 5,720 `diff -e` scripts** give the new
    file under both eds, with the same counts printed. The 4 others
    are files with Latin-1 bytes, which 9base's ed reads as runes,
    each invalid byte a U+FFFD written back as such, where TinyEd keeps
    the bytes -- a documented difference, `latin1`.
  - **Two more documented differences**, each with a `.tiny.out`: a
    line over 4,096 characters, which 9base refuses; and `v/x/d` on an
    empty buffer, after which 9base's `$` is -1 (its g marks line 0
    and gdelete deletes it).
  - Interrupt and hangup checked by hand: the same output as 9base's,
    and `ed.hup` written.
  - The corpus: 44 cases, 3 of them documented differences; a Testo
    suite of 57 (the `.mli` examples, the laws, the corpus).
  - **Lines: 1,264 of `.ml`** (1,007 without blanks and comments),
    against the 1,000 planned: Command 513, Regex 307, Address 132,
    Input 108, Text 97, Out 69, CLI 26, Main 12. The C: 2,121 for ed.c
    and 1,316 of libregexp's files for the part it uses; oed 1,794 and
    partial.
- **2026-09-23, phase 5: `editor/tiny/TinyEditor.ml`**, sam's command
  language: the buffer a string, dot a range, addresses as ranges,
  `x y g v` loops over matches, `{ }`, changes recorded against the
  text as it was and applied at the end of the command ("changes not
  in sequence" when they overlap), and the memoized backtracker of
  decision 2 as its matcher. 666 lines (531 of code), against the 450
  planned. `test.sh`: 28 scripts the same as 9base's `sam -d`, after
  taking out a stray `d` that 9base's sam prints after its numbers
  (plan9port's `%lud`). What sam's source taught, read for it
  (plan9port's `address.c`, `xec.c`, `cmd.c`): a command is parsed
  whole before it runs, unlike ed; dot after a loop is not the
  obvious one (the first change's range after an `x` of `c`s, the last
  deletion's position after an `x` of `d`s), so TinyEditor makes it
  the text made and its tests don't compare it; and 9base's sam has a
  broken character class (`[a-c]` matches only `a` and `c`, `[^ab]` a
  newline), so the tests use none.

## Verification

`make test` runs the corpus, the laws and the unit tests;
`editor/tests/history.sh` replays xix's history (milestone 2), which
takes a while and is not in `make test`; nor is `editor/tests/fuzz.py
[seed] [count]`, the fuzzer against 9base's ed.

## Out of scope

Screen editing, which is vi's and sam's terminal and not ed; `z`,
`x` (encryption) and the other commands of later eds (GNU ed's `H`,
`h`, `#`); ed's `-p` prompt (Plan 9's ed has none); POSIX basic
regular expressions (`\(`, `\{n\}`), which are not Plan 9's.

## Related work

[`notes_ed_related_work.md`](../related-work/notes_ed_related_work.md).
