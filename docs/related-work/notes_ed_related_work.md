# TinyEd vs. the rest of the editors

Where a tiny ed sits among the editors people use: the line editors
from QED to ed and its descendants sed and grep, the screen editors
that grew out of them (ex and vi) and beside them (TECO and Emacs),
Pike's sam and acme, which rethought ed's language, the regular
expression engines, and the teaching editors. What they do that TinyEd
won't, and which of their ideas fit in a program small enough to read.
Companions: [`notes_ed.md`](../tutorials/notes_ed.md) (how it works)
and [`plan_ed.md`](../plans/plan_ed.md) (what gets built). Principia
has no lineage file for editors yet; the dates below are from memory
unless a source is named, and are to be checked before relying on
them for teaching.

## The one-line version

| | What it optimizes for | What you write |
|---|---|---|
| QED (1965-68), ed (1971) | Editing on a teletype, and scripting | `3,5d`, `/re/`, `s/a/b/g`, `g/re/cmd` |
| sed (1974), grep (1973), awk (1977) | One of ed's ideas, as a filter | `sed s/a/b/`, `grep re`, `awk '/re/ {...}'` |
| ex and vi (1976-79), vim (1991) | The screen, with ed underneath | `:%s/a/b/g`, and keys on the screen |
| TECO (1962), Emacs (1976, 1984) | An editor as a programmable machine | macros, then Lisp |
| sam (1987), acme (1992) | Structure, not lines; the mouse for the rest | `,x/re/c/new/`, and clicks |
| vis (2014), kakoune (2011) | sam's structural regexps with vi's keys; selections first | `x/re/`, multiple selections |
| `editor/` (TinyEd) | Seeing what an editor does, as ed, checked against Plan 9's | ed, run by about 1,000 lines of OCaml (target) |
| `editor/tiny/TinyEditor.ml` | What an editor is, in sam's terms | sam's language, in one file (target 450 lines) |

## Part 1: the line editors

- **QED** (Butler Lampson and L. Peter Deutsch, Berkeley, 1965-66, for
  the SDS 940); Ken Thompson's QED for CTSS and then Multics
  (1967-68) added **regular expressions**, compiled to machine code
  on the fly -- the method of his "Regular Expression Search
  Algorithm" (CACM, 1968), which is the Thompson NFA. Dennis Ritchie's
  "An incomplete history of the QED text editor" tells it.
- **ed** (Thompson, Unix V1, 1971): QED cut down for a small machine
  -- no multiple buffers, and regular expressions without
  alternation (those came back in Plan 9's ed). Line addresses, `g`,
  `s`, and a temp file for the text: the design principia's ed.c
  still has.
- **em** (George Coulouris, Queen Mary College, 1975-76), "editor
  for mortals", added a single-line screen mode, and Bill Joy's
  **ex** (1976) grew from it and ed.
- **Software Tools' edit** (Kernighan and Plauger, *Software Tools*,
  1976): ed rewritten in Ratfor, as a book chapter, with its own
  pattern matcher -- the closest ancestor of this project's idea, a
  real editor small enough to teach. Its **Pascal** edition (1981)
  did it again.
- **GNU ed** (from 1993) and **BSD ed** are the eds in use today,
  POSIX's (basic regular expressions, `-p` for a prompt, `H` for
  error explanations). Plan 9's ed kept the old command set and took
  egrep's notation.

## Part 2: ed's ideas as filters

- **grep** (Thompson, 1973): `g/re/p` as a program, written overnight,
  as the story goes, when McIlroy asked for it.
- **sed** (Lee McMahon, 1974): ed's commands applied to a stream, for
  files too big for the editor's buffer.
- **awk** (Aho, Weinberger, Kernighan, 1977): patterns and actions,
  the regular expression as the address of a program.

Each took one idea of ed's and made it a filter; which is why an ed
tutorial explains sed and grep for free, and why a shared regex
engine is the first thing an ix of text tools needs.

## Part 3: the screen editors

- **vi** (Joy, 1976-79): ex's visual mode, the screen over the same
  ed-like command language (`:` is ex). **vim** (Bram Moolenaar, 1991)
  and **nvi** (Keith Bostic) are its heirs.
- **TECO** (Dan Murphy, MIT, 1962): characters and a programming
  language of one-letter commands. **Emacs** (Richard Stallman, from
  TECO macros, 1976; GNU Emacs, 1984-85, in Lisp) made the editor a
  programmable machine. xix's twin program for editing on a screen is
  efuns, an Emacs in OCaml.
- These are the ceiling of TinyEd's world: nothing here draws a
  screen.

## Part 4: sam and acme

- **sam** (Rob Pike, 1987; "The Text Editor sam", Software Practice
  and Experience, 1987): ed's language, redone. The buffer is a string
  and dot a range of characters; addresses are ranges (`#n`, lines,
  `/re/`, `a,b`, `a;b`); and **structural regular expressions**
  ("Structural Regular Expressions", Pike, EUUG 1987) replace `g` and
  `s` with loops over matches: `x/re/cmd` runs `cmd` on each match in
  dot, `y/re/cmd` on the text between them, `g/re/cmd` and `v/re/cmd`
  keep or drop dot, and `{ }` groups. Lines are one structure among
  others. Its matcher is the one libregexp has: the Thompson NFA with
  captures, the "Pike VM".
- **acme** (Pike, 1992-94): sam's command language in a window system
  of text, where any text can be clicked to run it. The editor as the
  user interface.
- **vis** (Marc André Tanner, 2014) and **kakoune** (Maxime Coste,
  2011): sam's structural regular expressions and multiple
  selections, with vi's modal keys.

`editor/tiny/TinyEditor.ml` is on this branch: sam's command language,
without the screen, as `sam -d` has it.

## Part 5: the regular expression engines

- **Backtracking** (Henry Spencer's regex library, 1986; Perl, PCRE,
  and most languages' today): simple, and exponential on patterns
  like `(a*)*b`; the rule is leftmost-first (the first alternative
  that matches), not longest.
- **The Thompson NFA and the Pike VM** (Thompson 1968; Pike's for sam,
  1987; Plan 9's libregexp; RE2, Russ Cox, 2010): all the ways at
  once, linear in the text. Cox's articles (2007, 2009) made the case
  for them again, and named the Pike VM.
- **DFAs** (egrep, Aho, 1970s; lex): the NFA's state sets computed
  ahead, fastest, and no captures.
- **POSIX** (1992) specified leftmost-longest with rules for captures
  that many implementations got wrong (Glenn Fowler's testregex found
  that).
- **Memoized backtracking** (the idea TinyEd uses; its plan, decision
  2): backtracking over the tree with a table of (node, position)
  pairs visited. With the table, backtracking in priority order finds
  what the Pike VM finds, in the same bound. The idea is old --
  "backtracking with memoization is the NFA", in Cox's articles and
  in parsing's packrat parsers (Bryan Ford, 2002) -- and it is the
  smallest program that has the Pike VM's answers.
- **The 30-line matcher**: Rob Pike's `match`, `matchhere` and
  `matchstar` (`c`, `.`, `^`, `$`, `*`), in Kernighan and Pike's *The
  Practice of Programming* (1999) and Kernighan's chapter of
  *Beautiful Code* (2007): the teaching version, which TinyEd's
  matcher grows from with classes, groups and alternation.

## Part 6: the teaching editors

- **kilo** (Salvatore Sanfilippo, 2016): a screen editor in about
  1,000 lines of C, with a tutorial built on it ("Build Your Own Text
  Editor", snaptoken, 2017). A screen and no command language: the
  other half of what an editor is.
- **Software Tools' edit** (Part 1) is the line-editor one, and still
  the model: an ed in a book.
- *The UNIX Programming Environment* (Kernighan and Pike, 1984),
  Appendix 1, and Kernighan's two ed tutorials (1978) are how ed has
  been taught; this project's tutorial is about its implementation
  instead.

## What TinyEd takes, and leaves

As for TinyMk and TinyRc, two levels:

- **The language, at the real end**: ed as Plan 9 has it, checked
  against 9base's ed, on principia's `mkenam` scripts, and on the
  `diff -e` scripts of xix's history.
- **The implementation, at the legible end**: lines in memory with an
  identity, a command loop that reads as it goes, and a matcher that
  is a backtracker with a memo.

**The ceiling, stated now**: no screen, no multiple buffers (QED's
and sam's), no undo but `u`'s, no POSIX notation.

## Postscript: the numbers (to come)

Once built: TinyEd's lines per module against the plan's targets,
ed.c's 2,121 with libregexp's 1,479, and oed's 1,794; the corpus
cases that print what 9base's ed prints; the `mkenam`s; and how many
of xix's `diff -e` scripts replay to the same file.
