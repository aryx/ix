# mini-rc vs. the rest of the shells

Where a tiny rc sits among the shells people use: the Unix lineage
from Thompson's to bash and zsh, rc and its descendants, the
structured shells that replace text with values, the research that
gave the shell a formal semantics, and the teaching shells. What they
do that mini-rc won't, and which of their ideas fit in a program small
enough to read. Companions:
[`notes_rc.md`](../tutorials/notes_rc.md) (how it works) and
[`plan_rc.md`](../plans/plan_rc.md) (what gets built). The author's
genealogy of the field is `principia/shells/lineage.txt`, and this
note follows its families.

## The one-line version

| | What it optimizes for | What you write |
|---|---|---|
| Thompson sh (1971), Mashey's PWB shell (1976) | Running commands, then scripts | Commands, `<` `>` `\|`; `if` and `goto` were separate programs |
| Bourne sh (1977), POSIX sh (1992) | A programming language for scripts | `if ... then ... fi`, `"$@"`, strings split on `$IFS` |
| csh (1978), tcsh | The interactive user | History, aliases, job control, `~`, a C-like syntax |
| ksh (1983), bash (1989), zsh (1990) | Everything sh does, plus everything interactive | sh, extended: arrays, `[[ ]]`, completion, prompts, a thousand options |
| rc (1989), es (1993), Inferno's sh | A small, regular language | Lists instead of strings, one quote, `if(cond) cmd` |
| fish (2005) | Friendliness at the terminal | A new, sh-like syntax; suggestions as you type |
| PowerShell (2006), nushell (2019), elvish (2016) | Structured data in pipes | Objects or tables through `\|`, not bytes |
| Oils (2017) | Running bash scripts, then replacing them | bash (osh), and a new language (ysh) |
| `shell/` (mini-rc) | Seeing what a shell does, on real rc scripts | rc, run by 1,634 lines of OCaml |
| `tiny/TinyShell.ml` | What a shell is, at its smallest | rc's core, in one file of 598 lines |

## Part 1: where it came from

- **Before Unix**, Louis Pouzin's RUNCOM for CTSS (1964) ran a file
  of commands, and Pouzin coined "shell" for Multics' command
  interpreter. (From the lineage file.)
- **Thompson's sh** (1971, Unix V1): commands, redirections, and from
  1973 pipes; `if` and `goto` were separate programs, which is how
  small the shell was. John Mashey's **PWB shell** (1975-76) added
  variables and more control flow.
- **Bourne's sh** (Stephen Bourne, Unix V7, 1979; developed from
  1976): the shell as a programming language, with `if ... fi`,
  `case`, `for`, here documents, and ALGOL 68's influence on its
  keywords -- and on its C source, written with macros to look like
  ALGOL. Its data type is the string, split on `$IFS`: the source of
  most of sh's quoting rules, and of `"$@"`.
- **csh** (Bill Joy, BSD, 1978): the interactive shell -- history,
  aliases, job control, `~`. As a scripting language it was famously
  weak ("Csh Programming Considered Harmful", Tom Christiansen, 1990s;
  from memory).
- **ksh** (David Korn, Bell Labs, 1983) merged sh's language with
  csh's interaction; POSIX standardized a subset of it as `sh` (IEEE
  1003.2, 1992). **bash** (Brian Fox, GNU, 1989) and **zsh** (Paul
  Falstad, 1990) are its heirs, and today's defaults.

## Part 2: rc and its family

- **rc** (Tom Duff, Bell Labs, 1989, for Plan 9 and Tenth Edition
  Unix; "Rc -- The Plan 9 Shell", 1990). Duff kept Bourne's
  semantics where they were right and changed the syntax and the
  values: every variable is a list, so there is no word splitting and
  no `"$@"`; the only quote is `'`; `if`, `for` and `while` take a
  command list in parentheses, so the grammar is 116 lines of yacc;
  functions and variables share the environment. It compiles commands
  to code for a small machine, run on a queue of threads (the design
  mini-rc does not follow; its plan, decision 1).
- **Rakitzis's rc** (Byron Rakitzis, 1991): an independent rc for
  Unix, 6,837 lines in its 1.2 (the lineage file) -- interesting
  because it is a second implementation of the same language, as
  mini-rc will be a third.
- **es** (Paul Haahr and Byron Rakitzis, USENIX 1993): rc with
  closures and higher-order functions, where even the shell's own
  operations (`|`, `>`) are functions you can redefine. The road not
  taken: a shell as a real functional language.
- **Inferno's sh** (1996): rc's syntax, with modules loaded into the
  shell, in Limbo.
- **plan9port's rc**, the one packaged as 9base and installed here,
  is Duff's rc on Unix, and mini-rc's reference.

## Part 3: the structured shells and the new ones

- **PowerShell** (Microsoft, 2006; open source 2016) sends .NET
  objects through pipes instead of bytes. **nushell** (2019) sends
  tables, and **elvish** (Qi Xiao, 2016) structured values. They
  answer sh's quoting problems by not having strings at the bottom --
  a step further than rc's lists, and a step away from Unix's
  programs, which read and write bytes.
- **fish** (Axel Liljencrantz, 2005; rewritten in Rust, 2023) is
  about the interactive experience: autosuggestions, syntax colors, a
  cleaned-up syntax.
- **Oils** (Andy Chu, from 2017; OSH and YSH) runs existing bash
  scripts faithfully, then offers a new language -- the most serious
  recent study of what sh's language actually is.

## Part 4: the shell as a research object

- **Smoosh** (Michael Greenberg and Austin Blatt, POPL 2020): an
  executable formal semantics of POSIX sh, tested against real
  shells. It found bugs in all of them.
- **Morbig** (Yann Régis-Gianas, Nicolas Jeannerod and Ralf Treinen,
  2017-2018): a static parser for POSIX shell, in OCaml, built for
  the CoLiS project's verification of Debian's maintainer scripts --
  and a demonstration of how hard sh is to parse (the grammar depends
  on the lexer, which depends on the parser).
- **PaSh** (EuroSys 2021) parallelizes shell scripts automatically;
  **Shill** (OSDI 2014) gives scripts capabilities -- the idea ix uses
  for its programs, applied to the shell's children.
- **scsh** (Olin Shivers, 1994): process notation embedded in Scheme,
  the other way round from a shell with a language -- a language with
  a shell.

## Part 5: the teaching lineage

- **Kernighan and Pike, *The UNIX Programming Environment*** (1984),
  chapters 3 and 5: sh as a programming language, taught by example.
- **Rochkind, *Advanced UNIX Programming*** (1985): the code of a
  mini-shell, the only shell source the Principia book could cite as
  explained elsewhere.
- **Principia's own mini-shells**, `shells/minishell/minishell1.c`
  and `minishell2.c`: 26 and 64 lines of C, a loop that reads a
  command and `exec`s it, then `>` and `|` added -- §1 of the
  tutorial, in C, at its smallest.
- **Bryant and O'Hallaron, *Computer Systems: A Programmer's
  Perspective*** (2003), whose "shell lab" has students write a shell
  with job control (tsh); and Stephen Brennan's "Write a Shell in C"
  (2015), a short, much-read tutorial. (From memory, to check.)
- **In OCaml**: xix's **orc** (mini-rc's twin, partial: the plan's
  Context); **Shcaml** (Alec Heller and Jesse Tov, 2008), a library
  for shell-style programming in OCaml; Morbig (above).

## Where `shell/` actually sits

As for mini-mk, two levels:

- **The language, at the real end**: rc as it is, checked against
  9base's rc on a corpus, on principia's scripts, and by running the
  recipes of xix's mkfiles for mini-mk.
- **The implementation, at the legible end**: a lexer and a
  recursive-descent parser, and an evaluator that walks the tree -- no bytecode, no
  thread queue -- with `fork`, `exec`, `dup2` and `pipe` in plain
  view.

**The ceiling, stated now**: no line editing, history or completion
(rc's choice, not only mini-rc's); no job control; no sh or POSIX
mode; Plan 9's namespaces (`rfork n`, `bind`, `mount`) only on
TinyKernel, later; signals as far as the plan's phase 5 decides.

## Postscript: the numbers

- **Lines.** mini-rc has 1,634 lines of `.ml`, 1,271 of them code,
  against the 1,500 planned: 6% over in total, with the parser at
  double its target and `Word` at half of its. That is 29% of the C
  rc's 5,678 and 57% of orc's 2,876, and orc is partial. TinyShell.ml
  has 598 lines, 423 of them code: a third of mini-rc.
- **The corpus.** 43 scripts. 39 print what 9base's rc prints, and 4
  are documented differences, each with a `.mini.out`: the split
  backquote twice, a missing program at the end of a subshell, and
  an `exec` that fails, after which 9base's rc spins forever. orc
  passes 4 of the first 36.
- **Principia's 133 scripts**, run with no arguments in a sandbox:
  120 print the same. Of the other 13, 4 are 9base's `exec` hang, 3
  use `` `sep{} ``, 1 is the subshell case, 3 print what changes
  from run to run, and 1 is a 9base quirk: a missing program in a
  pipe stage exits with the `$status` it inherited.
- **The xix build**: 33 s with mini-rc as mini-mk's shell, and 32.7 s
  with TinyShell. Both produce the same 435 files as omk with 9base's
  rc.
- **Startup**, 100 runs of `-c true`: 9base's rc 3.0 ms, mini-rc 4.9,
  TinyShell 5.0. The cost is OCaml's runtime and not rcmain, which
  TinyShell doesn't have. A build pays it once per recipe, about half
  a second over xix's.

Sources: from memory unless a file is named, and to be checked before
relying on them for teaching -- particularly the PWB and Bourne dates,
Christiansen's article, Rakitzis's line count (from the lineage file,
unchecked), and the teaching-lineage references.
