# A text editor, from scratch: a tutorial for `editor/`

What a line editor does, and how ed does it: a buffer of lines, a
current line, commands with addresses read one at a time, regular
expressions to find and change text, and the files the buffer comes
from and goes to. It is written for **a reader of TinyEd's code, not
a user of ed**, and explains the ideas in the order the code needs
them.

It is the specification of the program planned in
[`plan_ed.md`](../plans/plan_ed.md). It was written before the code and
then checked against it, as [`notes_rc.md`](notes_rc.md) was. It got
two things wrong, corrected here and listed in the plan's Status: how
TinyEd matches (§4: libregexp's own way, not the planned backtracker)
and the line count (1,264, not about 1,000). Every example
below was run on 9base's ed (`/usr/lib/plan9/bin/ed`) on 2026-09-23,
unless it says "to check". Companions:
[`notes_ed_related_work.md`](../related-work/notes_ed_related_work.md)
and the twins, the Principia book `editors/ed.nw` (the C ed) and xix's
`editor/` (oed).

## 0. Where the code is, and a reading order

| module (`editor/`) | what | section |
|---|---|---|
| `Text` | the buffer: lines, dot, the last line, marks, undo | §2 |
| `Input` | the command stream: stdin, pushback, `g`'s list | §3, §7 |
| `Address` | `.` `$` `3` `/re/` `'a` `+` `-` `,` `;`, and the defaults | §3 |
| `Regex` | Plan 9's notation, matched leftmost-longest | §4 |
| `Command` | the loop and every command; `s`, `g`, errors | §3, §5-§7, §10 |
| `Out` | `p`, `l`, `n`: printing a line | §8 |
| `CLI` | `-`, `-o`, the file argument, signals | §9, §10 |

Read §1 for the question, §2-§3 for the model, §4 for the algorithm,
§5-§10 for the commands, and §11-§14 for how TinyEd differs from its
twins, how it is tested, and what is left as exercises.

## 1. What an editor is, when there is no screen

The whole of ed in one session:

```
   $ ed hello.c                      read the file into the buffer
   42                                its size in bytes
   /main/                            find the next line matching main
   int main(void) {                    (printed: it is now the current line)
   s/void/int argc, char **argv/     change it
   .,+2p                             print it and the two lines after
   int main(int argc, char **argv) {
       printf("hello\n");
   }
   w                                 write the buffer back
   57
   q
```

There is no screen and no prompt: a line of input is a command, a
command prints only what it is asked to, and an error is `?`. The
model is small, and every command is defined in it: **a buffer of
numbered lines, a current line called dot, and commands that take up
to two addresses** -- lines, or a range from one to the other. ed is
from 1971, for a teletype, where printing the file after each change
was not an option; that is also what makes it scriptable, and why
`diff -e` still speaks it.

## 2. The buffer: lines with an identity

```
   index   0      1          2           3         ($ = dol = 3)
           .-----.----------.-----------.---------.
   lines   | (0) | "int x;" | "int y;"  | "}"     |
           '-----'----------'-----------'---------'
                             ^ dot = 2
```

Line 0 is not a line: it is where `0a` appends to, before the first.
Dot is a line number, and `$` (ed.c's `dol`) the last one; an empty
buffer has `$` = 0 and dot 0. A line is a string without its newline.

ed.c keeps the lines' text in a temporary file and the buffer as an
array of offsets into it, and it steals the low bit of each offset
for `g` (§6). TinyEd keeps the lines in memory, and **each line is a
record, whose identity matters**: a mark (`ka` names the current line
`a`, `'a` finds it again) holds the record, not the number, so it
follows its line when lines are moved or inserted above it, and it is
gone when its line is deleted:

```
   2ka          mark line 2 "y" as a
   1,2m3        move lines 1-2 after line 3: now x2 x1 y
   'ap          prints y: the mark followed its line
```

An `s` makes a new record for the line it changes, moves the marks of
the old one to it, and keeps the pair (old, new): `u` puts the old
one back, if the line there is still the new one (`u` twice is `?`,
and so is `u` on another line).

## 3. Addresses and the command loop

A command is `[address [, address]] letter [arguments]`. The
addresses:

```
   .        dot                  $       the last line
   3        line 3               'a      the line marked a
   /re/     the next line matching re, from dot, wrapping around
   ?re?     the previous one, wrapping around
   a+n a-n  n lines after, before; a lone + or - is 1, and they add up
   a,b      from a to b          a;b     the same, but dot = a before b is read
   ,        1,$                  ;       also 1,$ in this ed (ed.c, checked)
```

and each command has **defaults**: `p` and `d` are `.,.`, `w` and `g`
`1,$`, `a` `.`, `r` `$`, `=` `$`, and a newline alone is `.+1p`, so
typing return steps through the file. A command given more addresses
than it takes uses the last ones. A range must be in order and inside
the buffer, and most commands refuse line 0 (ed.c's `nonzero`); `a`,
`r` and `=` accept it.

The loop, ed.c's `commands()`, reads an address, then a character,
then what that command reads itself:

```
   input     2,/end/-1p
   address   2                     -> 2
   ','       second address
   address   /end/ -> search from dot, line 7; then -1 -> 6
   'p'       print 2..6, dot = 6
```

There is no parser. **Addresses act while they are read**: `;` sets
dot before the next one, and `/re/` becomes the remembered pattern
(an empty `//` means it), which `s//x/` then uses. And a command reads
its own arguments from the same input: `a` reads lines until one is
`.`, `s` reads a pattern and a replacement that may go on past a `\`
at the end of a line, `w` a file name. So TinyEd keeps ed.c's shape:
the loop and the commands read from one input with one character of
pushback (ed.c's `peekc`).

## 4. Regular expressions, and how to match them

The notation is Plan 9's, "the form used by egrep before egrep got
complicated" (regexp(7)):

```
   c        a character          \c      c, when c is special (or the delimiter)
   .        any character        [a-z]   a class     [^a-z]  its complement
   ^  $     start, end of line
   e*  e+  e?                    zero or more, one or more, zero or one
   e1e2  e1|e2  (e)              concatenation, alternation, a group (and a capture)
```

No `\(`, no `\{n,m\}`, no `\<`: parentheses group and capture with no
backslash, and `+`, `?`, `|` are there. A pattern with no match on a
line is `?` as an address, and nothing done as part of `s` or `g`.

**Which match.** A line can match in many places and many ways; ed
takes **the leftmost, and of those the longest** (the POSIX rule, and
libregexp's):

```
   s/o|on/X/        on "one"     ->  Xe          (on, not o: longest)
   s/(a*)(a*)/[\1,\2]/   "aaa"   ->  [aaa,]      (the first group takes all)
   s/(o|on)(e|ne)*/[\1,\2]/ "one" -> [o,ne]      (both ways are longest:
                                                  which one, see below)
```

The last line is the subtle one: when several ways of matching give
the same longest match, which one's captures you get is not fixed by
the notation. It is decided by how libregexp runs the pattern, and ed
is specified by libregexp, so that is what TinyEd has to copy.

**How libregexp does it.** It compiles the pattern to a small program
(`RUNE c`, `ANY`, `CCLASS`, `OR` with two successors, `LBRA n` and
`RBRA n` for the captures, `END`), and runs every way at once: a list
of "threads", each an instruction with its own copy of the captures,
advanced together over the line one character at a time. Two threads
at the same instruction on the same character would do the same thing
from then on, so only one is kept, the one that started earlier or
else the first in the list. That is Thompson's 1968 construction with
captures added -- what Russ Cox calls the Pike VM, from its use in Rob
Pike's sam -- and it never takes more than instructions x characters
steps. Three details of it decide the corner cases:

```
   the order     an OR follows its left side at once, and puts its right
                 side at the END of the list; the left of * + ? is the
                 skip, and of a|b it is b
   the dedup     an OR's right side is checked only against the threads
                 not run yet, so a loop that can match empty adds the
                 same instruction again, and again
   the overflow  the list holds 10 threads, then 50; past that, -1,
                 which ed takes for a match: the best found so far
```

So `((x?)?)*` on `xxb` matches the empty string (checked on 9base):
the list overflows, and the empty match at 0 was the only one found.

**How TinyEd does it: the same way.** The plan chose something that
looks different and gives the same answers: backtracking over the
pattern's tree, keeping the longest end and the captures of the first
path to reach it, and remembering each (node, position) pair visited,
so that no pair is tried twice:

```
   pattern (a|ab)(c|bcd)       line "abcd"
   try a     at 0 -> 1:  then (c|bcd) at 1: c fails, bcd -> 4   end 4, \1=a
   try ab    at 0 -> 2:  then (c|bcd) at 2: c -> 3              end 3 (shorter)
   result: "abcd", \1 = a, \2 = bcd
```

The memo makes it a Pike VM, in the same bound, and a second visit to
a pair can only find ends already found, by a path of lower priority.
So its answers are those of a Pike VM whose threads are in priority
order, like RE2's. libregexp's are not in priority order, and a fuzzer
against 9base's ed found the difference in its first 5,000 scripts.
So TinyEd compiles to regcomp's program and runs regexec's lists,
sizes and overflow included. One more thing the fuzzer found is in the
parser: regcomp applies postfix operators through its operator stack,
where `*` < `+` < `?`, so `x*+` is `(x+)*`. The backtracker lives on
in `tiny/editor/TinyEditor.ml`, where there is no reference to match
in the corners.

**Unicode.** A line is UTF-8 bytes, and positions are byte offsets;
the matcher decodes one character at each step, so `.` and `[^x]`
take `é` whole (checked: `s/h./X/` on `héllo` gives `Xllo`), and `s`
works on bytes.

## 5. Substitution

```
   (.,.)s/re/replacement/      the first match on each line
   (.,.)s/re/replacement/g     every match
   (.,.)s3/re/replacement/     the third match (and with g, the third and after)
```

In the replacement, `&` is the match, `\1`-`\9` the groups, `\&` a
`&`, and `\` then a newline splits the line there. Any character but
blank and newline can be the delimiter. A final delimiter left out
means "and print" (`s/a/b` is `s/a/b/p`). An `s` that changes no
line is `?`, and dot is the last line changed.

Two details are the whole difficulty:

- **The empty match with `g`.** `s/x*/-/g` on `abc` gives `-a-b-c-`
  (checked): after an empty match the search goes on one character
  further, or it would loop.
- **The n-th with `g`.** `s2/a/Y/g` on `aXaa` gives `aXYY` (checked):
  count the matches, replace from the second on.

A `\1` naming a group that did not match is `?` (checked). A
replacement with newlines makes several lines from one: the first
replaces the line, the others are appended after it, and the range
of the `s` is moved down by as many.

## 6. Global commands, in two passes

`g/re/cmds` runs `cmds` on every line matching `re`, with dot on
that line; `v` on every line not matching. It does it **in two
passes**: first it marks the matching lines (in ed.c the low bit of
the offset, in TinyEd the line record's flag), then it walks the
buffer, and for each marked line clears the mark, sets dot and runs
the list. Why not one pass: the list may delete or move lines, or add
some; the marks are on the lines, so they survive that, and a line
the list deleted is simply no longer there to visit.

The list is the rest of the line, with `\` newline to continue it on
the next, and it is run by reading it again for each line, as if it
were typed (§7): so `g/x/a\` then `new` appends `new` after every line
with an `x`, and the final `.` of `a` may be left out (checked). `g`
inside `g` is `?`. And `g/re/d` alone is done in one pass (ed.c's
`gdelete`), because line by line it would be quadratic.

## 7. Where input comes from

Three readers share one stream:

- the command loop, a character at a time (`getchr`);
- input mode, for `a`, `i`, `c`: whole lines until one that is `.`;
- `g`'s command list, a string in front of the stream while it runs
  (ed.c's `globp`): when it is used up, it is an end of file for that
  line's run, and `g` moves to the next line.

ed reads standard input **one byte at a time**, as plan9port does.
It is slower, and it is why `!cat` given the rest of a script reads
it: the child gets what ed has not read. `!cmd` runs `rc -c cmd`,
waits, and prints `!` (unless `-`).

## 8. Printing a line

`p` prints the lines, `n` each with its number and a tab, `l`
unambiguously: a tab as `\t`, a backspace as `\b`, a backslash as
`\\`, any other character outside printable ASCII as `\x` and four
hex digits (`\x0001`, and `é` as `\x00e9`, checked), a blank at the
end followed by `\n`, and a line longer than 64 columns folded, with
`\`, a newline and a tab. `p`, `l` and `n` can follow most commands
(`s/a/b/p`, `dp`), to print the new dot. `=` prints the line number
of its address (`$` by default); `b` a page (20 lines, then the
size given: `b5`) forward, or backward with `b-`.

## 9. Files

```
   e file    the buffer replaced by file (? if changed since the last w; E: anyway)
   r file    file read after the addressed line ($)
   w file    the addressed lines (1,$) written;   W file: appended
   f file    the remembered name set; f alone prints it
```

Each prints the number of bytes read or written (unless `-`). The
**remembered file name** is the argument of `ed file`, of `e`, of
`f`, or the first `r` or `w` if there was none, and a command given
no name uses it. `wq` writes and quits. A file whose last line has no
newline is read with one added, and says so (`'\n' appended`,
checked), and a NUL in a line cuts it there (`a\0b` is read as `a`,
checked: ed.c's lines are C strings; the man page says NULs are
discarded).

With `-o`, the remembered file is standard output and everything
else goes to standard error: `ed -o < script` is a filter.

## 10. Errors, quitting, and signals

An error prints `?` (or `?name` for a file that can't be opened) on
standard output and goes back to the loop; the rest of the line is
thrown away, and `g`'s list too. One more thing, easy to miss: **if
standard input is a file, the rest of it is skipped** (ed.c seeks it
to its end). So

```
   ed f < script        stops at the first error
   cat script | ed f    goes on after it
```

(checked, both). `q` and `e` with changes not written are `?` once,
and work the second time; with `-`, they never complain. An interrupt
prints `?` and returns to the loop; a hangup writes the buffer to
`ed.hup` and quits.

## 11. Compared with ed.c and oed

| | ed.c (C, principia) | oed (OCaml, xix) | TinyEd |
|---|---|---|---|
| the buffer | offsets into a temp file, low bit stolen | lines in memory | lines in memory, records with identity |
| input | `getchr`, `peekc`, `globp` | ocamllex | `getchr`, `peekc`, `globp` |
| regular expressions | libregexp: compiled, Pike VM | the `re` library | libregexp's program and lists, in OCaml |
| `s///g`, `&`, `\1`, marks, `g` | yes | no | yes |
| lines | 2,121, and libregexp 1,479 | 1,794 | 1,264 (1,007 of code) |

The design difference that matters is the first row (the plan's
decision 1): lines as records in memory, with an identity. The third
row was planned as the other difference, and went back to the C's
design (§4).

## 12. How it is tested

- **Differential tests**: a corpus of scripts, each with a file to
  edit, recorded from 9base's ed: the output, the exit status, and
  every file written.
- **Laws**: `diff -e a b` makes `a` into `b`; `s` then `u` is nothing;
  `m` and `m` back is nothing; `g/re/p` is `grep re`.
- **Real scripts**: principia's two `mkenam`s, and the `diff -e`
  scripts of xix's last 3,000 commits: 5,716 of 5,720 the same, the
  other 4 files with bytes that are not UTF-8, which 9base's ed
  rewrites.
- **A fuzzer**: random scripts on random files, through both eds;
  10,000 the same, but for one where 9base's ed crashes.

## 13. Exercises

- **An undo of everything**, not only the last `s`: keep the buffer's
  lines array before each command (the records are shared, so it is
  cheap), and `u` swaps it back.
- **POSIX's notation**, `\(` `\)` `\{m,n\}`, as a second front end to
  the same tree.
- **A prompt** (GNU ed's `-p`), and `z` to scroll.
- **The matcher as a DFA**: the (node, position) memo is a set of
  states per position; computing those sets ahead of time is the
  subset construction, grep's way.

## 14. In ix

TinyEd is the editor of the ix user who has a terminal and no screen,
and its regular expressions are the first piece of text processing
the other programs can share (a grep, a sed, sam's language in
`tiny/editor/`). TinyEditor.ml, in `tiny/editor/`, came after it:
one file, sam's structural regular expressions instead of ed's lines,
tested against 9base's `sam -d`.

## Glossary

- **Buffer**: the lines being edited; a copy of the file until `w`.
- **Dot**: the current line (§2).
- **Address**, **range**: a line, and a pair of them (§3).
- **Leftmost-longest**: the match rule, POSIX's and Plan 9's (§4).
- **Pike VM**: Thompson's NFA simulation with captures (§4).
- **Mark**: `k`'s name for a line, which follows the line (§2).

## References

- Ken Thompson, "Regular Expression Search Algorithm", CACM 11(6),
  1968.
- Brian W. Kernighan, "A Tutorial Introduction to the UNIX Text
  Editor" and "Advanced Editing on UNIX", Bell Labs, 1978.
- Brian W. Kernighan and Rob Pike, *The UNIX Programming Environment*
  (1984), Appendix 1.
- Russ Cox, "Regular Expression Matching Can Be Simple And Fast"
  (2007) and "Regular Expression Matching: the Virtual Machine
  Approach" (2009).
- regexp(7), ed(1) of Plan 9; principia's `editors/ed.nw`.
