# Plan: TinyRc, a shell from scratch, for teaching (`shell/`)

Companions:
[`notes_rc.md`](../tutorials/notes_rc.md), the tutorial: what happens
when you type `ls`, words and lists, globbing, fork and exec,
redirections and pipes, control flow, functions and the environment,
and how rc starts. And
[`notes_rc_related_work.md`](../related-work/notes_rc_related_work.md):
from Thompson's sh to Bourne's, csh, ksh, bash and zsh, rc and es, the
structured shells, the formal semantics, and the teaching shells. The
twins are the Principia book `shells/Shell.nw` (rc in C, 5,678 lines
by the book's own count, 6,879 in `SRC/cmd/rc/*.[chy]` without the
generated parser) and xix's `shell/` (orc, rc in OCaml, 2,876 lines of
`.ml`, `.mll` and `.mly`).

The second ix program, after TinyMk ([`plan_mk.md`](plan_mk.md)),
and planned the same way; the principles are now in
[`../README.md`](../README.md).

## Context

The shell is "a thin layer around the kernel" (the Principia book's
introduction) that runs commands in a terminal, and the programmer's
most used program after the editor. Its questions are the book's:
what happens when you type `ls`; how redirections and pipes are made
from system calls; why `ls` is a program but `cd` a builtin; how `^C`
reaches the right process.

rc is Tom Duff's shell for Plan 9 (1989, "Rc -- The Plan 9 Shell"),
and a cleaner language than sh: every variable is a list of strings,
so there is no word splitting of `$x` and no `"$@"`; the only quote is
`'`; `if`, `for`, `while` and `switch` take a parenthesized list; and
the grammar is a yacc file of 116 lines.

Why rc second:

- **It is TinyMk's shell.** Principia's and xix's mkfiles run their
  recipes with rc, and TinyMk built all of xix with 9base's rc as
  `MKSHELL`. TinyMk and TinyRc building xix together is the
  milestone: two ix programs doing real work, without their full-size
  twins.
- **A reference runs today**: 9base's rc, `/usr/lib/plan9/bin/rc`
  (plan9port's, as Debian packages it), as 9base's mk was TinyMk's.
- **xix's twin is partial.** orc is 2,876 lines and stops on a
  17-line script of the most common rc (checked 2026-09-23): no `$"x`
  ("TODO compile: Stringify"), no `^` on a variable ("TODO compile:
  Concat"), and `$x(2)` prints `a b c 2` instead of `b`. So TinyRc
  can be, unlike TinyMk, both smaller than its OCaml twin and more
  complete, and the comparison that matters is with 9base.

## Principles

Those of [`../README.md`](../README.md), and three of its own:

- **Scripts are the inputs.** Where TinyMk had mkfiles, TinyRc has
  scripts: principia's rc scripts (133 distinct, 6,442 lines) and the
  recipes of principia's and xix's mkfiles (247 distinct mkfiles,
  4,110 recipe lines). The feature table below is counted over them.
- **The interactive shell is a script read from the terminal.** One
  reader, one evaluator, for a script, `-c`, `.` and the prompt; no
  line editing, as in rc, where the window system (rio) edits.
- **Plan 9 names on a Unix host.** rc assumes Plan 9 (`rfork`, `/env`,
  `/dev/cons`); on the host TinyRc does what 9base's rc does, which is
  usually to accept and do nothing. On TinyKernel, later, the same
  builtins become real.

## The interface: rc's, unchanged

rc's language, command line (`rc [-eiIlrvx] [-c cmd] [-m rcmain]
[file [arg ...]]`) and builtins are kept. A script 9base's rc runs,
TinyRc runs the same way. How often each feature is used, counted by a
script over the two corpora (files using it, and occurrences; comments
and single-quoted strings removed first, binaries and duplicates
skipped, 2026-09-23):

| feature | rc scripts (133) | mkfile recipes (247) | TinyRc |
|---|---:|---:|---|
| `$*`, `$1` ... | 79 / 297 | 1 / 3 | kept |
| `x=y` assignment | 77 / 536 | 9 / 92 | kept |
| `\|` pipe | 64 / 185 | 23 / 108 | kept |
| `if( )` | 62 / 322 | 7 / 20 | kept |
| `` `{ } `` command substitution | 59 / 221 | 8 / 12 | kept |
| globbing `*` `?` `[` | 56 / 185 | 52 / 257 | kept |
| `~` pattern match | 53 / 265 | 4 / 11 | kept |
| `rfork` | 53 / 61 | 4 / 16 | kept, a no-op on the host (as 9base) |
| `$#x` count | 52 / 156 | 0 | kept |
| `>` redirect | 51 / 126 | 46 / 95 | kept |
| `>[2]`, `>[2=1]` fd redirects | 51 / 99 | 3 / 5 | kept |
| `exit` | 48 / 104 | 2 / 3 | kept |
| `&&` `\|\|` | 43 / 155 | 13 / 19 | kept |
| `(a b)` lists | 35 / 100 | 1 / 4 | kept |
| `.` (source) | 34 / 51 | 0 | kept |
| `for( )` | 33 / 51 | 38 / 106 | kept |
| `cd` | 32 / 77 | 44 / 96 | kept |
| `fn` definitions | 25 / 65 | 1 / 1 | kept |
| `switch( )` / `case` | 24 / 45 | 3 / 4 | kept |
| `^` explicit concatenation | 24 / 68 | 7 / 11 | kept |
| `exec` | 24 / 39 | 6 / 8 | kept |
| `<` input | 23 / 33 | 6 / 8 | kept |
| `if not` | 22 / 77 | 0 | kept |
| `@{ }` subshell | 20 / 48 | 25 / 83 | kept |
| `>>` append | 17 / 32 | 8 / 19 | kept |
| `shift` | 17 / 57 | 1 / 1 | kept |
| `eval` | 16 / 16 | 2 / 2 | kept |
| `$x(n)` subscripts | 13 / 53 | 0 | kept |
| `$status` | 13 / 20 | 0 | kept |
| `while( )` | 12 / 17 | 0 | kept |
| `!` negation | 12 / 32 | 1 / 2 | kept |
| `$"x` join | 7 / 8 | 4 / 6 | kept |
| `path=` | 7 / 9 | 0 | kept |
| `<<` here documents | 6 / 14 | 1 / 1 | kept |
| `&` background | 4 / 5 | 3 / 7 | kept (and `$apid`, `wait`) |
| `<{ }` `>{ }` pipe substitution | 3 / 9 | 0 | kept, late (phase 5) |
| `flag` | 3 / 3 | 0 | kept |
| `ifs=` | 3 / 3 | 0 | kept |
| `\|[2]` pipe of another fd | 2 / 2 | 0 | kept |
| `wait`, `whatis` | 0 | 3 / 3, 0 | kept: interactive use needs both |

Nothing is dropped a priori, and the counts say why: the rarest
features are used by real scripts too, and each costs a few lines
once the core exists. The ones to decide by lines when they come
(phase 5): `<{ }` (a named pipe per use), and signal handlers (`fn
sigint`), which no script of the corpora defines -- and which the
counts can't see, because they matter at the terminal, not in scripts.
That is the kind of choice the counts guide and a judgment makes.

The command's name: `tinyrc`, as `tinymk`.

## Target layout

```
shell/                   library ix_rc + the tinyrc executable
  Ast.ml                 commands and words, as the parser builds them
  Lexer.ml(i)            by hand: rc's tokens, free carets, keywords
                         only where a command starts, newlines after
                         | && || swallowed
  Parser.mly             menhir: syn.y's grammar (decision 2)
  Word.ml(i)             a word to a list of strings: $x, $#x, $"x,
                         $x(n), ^ and its distribution, quoting kept
                         for globbing
  Glob.ml(i)             * ? [...] against the directory tree
  Env.ml(i)              variables and functions; import and export
                         (lists joined by \001, functions as fn#name)
  Process.ml(i)          fork, exec, wait, $path, redirections and
                         pipes as file descriptors, through Cap
  Eval.ml(i)             the evaluator: the syntax tree, walked
                         (decision 1)
  Builtin.ml(i)          cd exit shift eval . exec wait whatis flag
                         rfork, and friends
  CLI.ml(i), Main.ml     flags, rcmain, -c, a script, the prompt
shell/tests/             Testo: the .mli examples, the laws, the corpus
shell/tests/corpus/      scripts, each with its output recorded from
                         9base's rc
shell/tiny/              TinyShell.ml, later (see "Outside rc")
```

Eleven modules; orc has 24. **The size target**: about 1,500 lines of
`.ml` and `.mly` -- a quarter of the C rc, half of orc, and complete
where orc is not. It is set by module this time (Lexer 200, Parser
130, Ast 60, Word 200, Glob 60, Env 100, Process 150, Eval 300,
Builtin 200, CLI 100), because TinyMk's single figure was 2.4 times
too low; the Status will compare.

## Groundwork decisions

### 1. Walk the syntax tree: no bytecode, no run queue

rc compiles each command to code for a small machine (`code.c`, 483
lines), and runs it on a queue of threads (`exec.c`, `executils.c`,
`processes.c`: some 1,100 lines), one per nested `.` or function
call, each with its own program counter and stack of lists. orc
follows it (`Compile`, `Opcode`, `Interpreter`, `Runtime`,
`Op_process`, `Op_repl`). The machine buys rc two things: `.` and the
terminal can feed the same queue a line at a time, and after `fork`
the child simply goes on running code at the right pc.

An OCaml evaluator gets both from recursion. Reading is incremental
anyway (the parser is asked for one command at a time, for the
terminal, a script or `.`); and after `fork` the child evaluates the
subtree it was forked for and exits with its status. `exit` is an
exception that unwinds to the top; rc has no `break` or `return` (on
9base both are "No such file or directory": commands like any other),
so nothing else needs one. That removes the compiler, the opcodes and
the thread queue -- about a third of the C.

**What to watch**: rc's behaviour where the machine shows through.
`$status` after each command, `if not` (the one construct that
remembers the previous command's outcome), the order of redirections
and forks in a pipeline, and signals, which rc checks between
instructions and TinyRc will check between commands. Each gets a
corpus case, and the Status says if the tree walker had to bend.

### 2. The grammar in menhir; the lexer by hand

This time the grammar nests -- commands inside braces inside `if`,
`for`, `while`, `switch`, `fn` and `@`, pipes, `&&` and `||`, `!` --
and it has operator precedence: what the README's principle 9 calls
for yacc. rc's own `syn.y` is 116 lines, and is its specification.

The lexer is by hand, because rc's needs state: a word followed by a
word with no blank between is a **free caret** (`$x.c` is `$x^.c`),
keywords are keywords only where a command starts, a newline right
after `|`, `&&` or `||` is not the end of a command, and `if not` is
two words that the lexer must see together. That is how `lex.c` does
it (324 lines), and orc's `Lexer.mll` needs the same flags.

**Measured in phase 1**: if the menhir grammar comes out longer or
harder to read than a recursive descent, the plan switches and says
so.

### 3. A word keeps its quoting until globbing

rc globs after expansion, and only the pattern characters that were
not quoted: `'*'.c` is literal, `$x.c` with `x='*'` is literal too,
but `*.c` is a pattern. rc marks unquoted `*`, `?` and `[` with a
special byte as it expands. TinyRc keeps it as a type: an expanded
word is a list of pieces, each quoted or not, and the glob looks only
at the unquoted ones. A pattern that matches nothing stays itself
(`nomatch*` prints `nomatch*`, checked).

### 4. `$status` is a string, and a pipeline's is a list joined by `|`

A command's status is the empty string for success and the exit code
otherwise (and something naming the signal for a killed process: its
exact form is to check in phase 3); a pipeline's is the stages' statuses
joined by `|`, so `true | false` leaves `|1` (checked on 9base).
`if`, `while`, `&&` and `||` test "all empty".

### 5. The environment: lists joined by `\001`, functions exported

As TinyMk found for its recipes: a list goes to a child joined by
`\001`, and comes back split; an empty list is not exported at all
(an empty `/env` file is `()` on Plan 9). Functions are exported
too -- `fn f {...}` then `rc -c f` runs it in the child, checked on
9base -- as an environment variable `fn#f={echo in f $*}` (checked:
the body as `whatis` prints it), which orc's Prelude lists as missing.

### 6. rcmain, the bootstrap script

rc starts by running `rcmain` (`/rc/lib/rcmain` on Plan 9), which
reads the profile and then the script, the `-c` command or the
terminal. TinyRc embeds plan9port's rcmain, as a string, overridable
with `-m`. xix's `shell/data/rcmain-unix` is the same idea, and was
what orc needed to run at all (`-m`).

### 7. On the host: what Plan 9 has and Unix doesn't

`rfork` is accepted and does nothing (9base: `rfork e` succeeds,
status empty); `$path` is a list kept in step with `$PATH`, joined by
`:`, as plan9port does (checked: `path=(/bin /usr/lib/plan9/bin)`
makes `$PATH` `/bin:/usr/lib/plan9/bin`). `/dev/cons`, `bind`
and `mount` are not the shell's business -- they are commands.

### 8. Where the code goes

`shell/`, xix's name (principia's is `shells/`), as `builder/` was
xix's. The binary is `tinyrc`; the free variant goes in `shell/tiny/`.

## Outside rc: TinyShell.ml

As TinyBuildSystem.ml followed TinyMk, `shell/tiny/TinyShell.ml`
follows TinyRc: one file, no compatibility, only what a shell is --
"the power of pipes, redirections, variables, and basic control flow
constructs" (the Principia book's introduction). It is written
**after** TinyRc, from what writing TinyRc taught, as the author
asked; this plan does not design it, only records the question it
will answer: which of rc's features are fundamental enough. The
starting guess, to be revised then: commands, quoting, lists as the
only value, `$x`, `^`, globbing, `|`, `<` `>` `>>`, `&&` `||`, `if`,
`for`, `fn`, `` `{} ``, `&`, `cd` and `exit`; and a real script to
prove it, as TinyBuildSystem built TinyMk -- probably the recipes of
xix's mkfiles, run by TinyMk.

## The modules, with their references

The ideas, with their diagrams and numbers, are in
[`notes_rc.md`](../tutorials/notes_rc.md); this is the map to the
sources (from memory where not linked, to check when each `.mli` is
written):

- **Lexer, Parser** (§2): Tom Duff, "Rc -- The Plan 9 Shell" (1990;
  `principia/shells/docs/rc.ms`); principia's `lex.c` and `syn.y`;
  menhir (François Pottier and Yann Régis-Gianas).
- **Word** (§3): rc(1), "Variables", "Concatenation", "Free carets";
  principia's `exec.c` (Xconc, Xcount, Xsub, Xqdol).
- **Glob** (§4): principia's `glob.c`; glob(7).
- **Process** (§5, §6): principia's `simple.c` and `processes.c`;
  pipe(2), dup2(2), execve(2); W. Richard Stevens, *Advanced
  Programming in the UNIX Environment* (1992), for the fds.
- **Eval** (§7): `syn.y` and `code.c` for what each construct means.
- **Env** (§8): principia's `var.c`, `env.c`, plan9port's `unix.c`.
- **Builtin** (§5, §8, §10): principia's `builtins.c`.
- **CLI** (§10): principia's `main.c`, `rcmain.rc`.

## Tests (what the program is for)

- **The corpus**, `shell/tests/corpus/`: one small script per feature
  of the table and per quirk found, principia's `ROOT/tests/rc/` (5
  scripts) and xix's `tests/rc/` (9), each with its stdout, stderr
  and exit status recorded from 9base's rc -- TinyMk's
  `differential.sh`, for scripts.
- **The laws**: `whatis` prints what re-reads as the same (for each
  function of the corpus, print, read, print again: the same text); a
  pipeline of n commands leaves a status of n parts; `{cmd}` and
  `@{cmd}` print the same when cmd changes no variable and no
  directory.
- **Milestone 1: principia's scripts.** Those of the 133 that make
  sense on a Unix host (`ROOT/rc/bin`'s `lc`, `man`'s helpers, ...),
  run by TinyRc and by 9base's rc on the same input: the same output.
  The count that do, and why the others don't, go in the Status.
- **Milestone 2: TinyMk and TinyRc build xix.** `MKSHELL=tinyrc
  tinymk MK=tinymk all` in a copy of xix: the same 476 files as with
  9base's rc -- two ix programs doing a real build with neither of
  their full-size twins.
- **Milestone 3: an interactive session**, scripted through a pipe:
  the prompt, a command, a pipe, `cd`, `^D`.

## Phasing

0. **Groundwork**: `shell/`'s dune, the corpus harness, the first
   cases recorded from 9base's rc (the 14 test scripts of principia
   and xix, and the semantics checks of this plan's Status).
1. **Lexer, Parser, Ast**: every script of the two corpora parses; a
   printer for `whatis`; the round-trip law. Measure the grammar
   (decision 2).
2. **Words and globbing**: `$x`, `$#`, `$"`, `$x(n)`, `^` and free
   carets, quoting, `` `{} ``, globbing. Tests: the `.mli` examples.
3. **Commands**: fork, exec, `$path`, `$status`, redirections, pipes,
   `&&` `||` `!`, the environment in and out, `cd` `exit` `shift`
   `eval` `.` `exec`.
4. **Control flow and functions**: `if`, `if not`, `for`, `while`,
   `switch`, `~`, `fn`, local assignments, `@{}`, `&`, `wait`,
   `$apid`, `whatis`.
5. **The rest**: here documents, `<{}` `>{}`, `|[2]`, `>[2=1]`,
   `flag`, `rfork`, `ifs`, signal handlers (decided by lines),
   rcmain and the command-line flags, the prompt.
6. **The milestones**: principia's scripts; TinyMk and TinyRc build
   xix; the interactive session; the LOC count against the twins.
7. **`shell/tiny/TinyShell.ml`**, from what phases 1-6 taught.
8. **Docs**: `notes_rc.md` checked against the code, the numbers
   filled in.

## Status

- **2026-09-23, the plan written, for review before any code** (the
  author: "let's do what we did for the build system to the shell,
  first generate the documents that I'll review. Once reviewed we can
  do a tiny rc under shell/ (or shells/), and later on from the
  experience writing a tiny rc we can do a TinyShell.ml under
  shell/tiny/"; and, for the feature counts, "you can also look at
  shell script (or mkfile) in ~/principia/", "this also requires
  judgments, not just statistics").
- **2026-09-23, the principles moved** to `docs/README.md`, as
  `plan_mk.md` said they would when a second plan started, with what
  TinyMk taught added (a runnable reference, the program over the man
  page, documented differences, a target set by module).
- **2026-09-23, the counts behind the feature table**: a script
  (regular expressions per construct, after removing comments and
  single-quoted strings, which may span lines) over principia's rc
  scripts -- files with an rc `#!` line or named `*.rc`, 215 found,
  133 once binaries and duplicates (`ROOT/arch/*/bin/git` copies
  `version_control/git9`) are left out -- and over the recipes of the
  474 mkfiles of principia and xix (247 distinct). Two slips of the
  script on the way, kept for the next count: `#` taken as a comment
  in `$#x` (which then counted 0), and awk programs in multi-line
  quotes counted as rc (`<` in 552 places). Counts of files and
  occurrences, not of meaning: a crude `<` or glob can still
  miscount.
- **2026-09-23, checked on 9base's rc before writing the tutorial**:
  `x=(a b c)` gives `$#x` 3, `$x(2)` b, `$"x` "a b c"; `a^(b c)` is
  `ab ac`, `(a b)^(c d)` is `ac bd`, and `(a b)^(c d e)` is a fatal
  "mismatched list lengths in concatenation"; `$x.o` distributes
  (`a.o b.o c.o`: free carets, where mk glues at the ends); `` `{echo
  one two} `` is two words; `false` leaves status `1` and `true |
  false` leaves `|1`; `*.c nomatch*` gives `a.c b.c nomatch*`; `x=(p
  q) echo $x` prints `p q` and leaves `$x` as it was; `whatis f`
  prints `fn f {echo in f $*}`; a function reaches a child rc;
  `rfork e` succeeds and does nothing; and in a here document `$x(1)`
  is `a b c(1)` -- the variable expanded, not the subscript; `return`
  and `break` are not rc (9base runs them as commands, "No such file
  or directory"); an unquoted `=` in an argument is a syntax error
  (`echo status=$status`: "token '=': syntax error", which the checks
  themselves ran into); functions are exported as `fn#f=` with their
  body; `$path` and `$PATH` stay in step. orc, on the same script:
  stops at `$"x`, and prints `$x(2)` as `a b c 2`.

- **2026-09-23, more checks on 9base's rc, for the tutorial's
  examples**: `$x(2 3)` is `b c`; `y='*'; echo $y` prints `*`
  unglobbed; `e >f1 >[2=1]` sends both streams to `f1`, `e >[2=1]
  >f3` only standard output (standard error goes where standard
  output was); `<<'EOF'` expands nothing; `for(i)` loops over `$*`;
  `fn l` deletes `l`, which then runs as a program ("No such file or
  directory", status 1); `*/*.c` reads two levels, sorted; `<{true}`
  is `/dev/fd/5`. Two of the checks were themselves wrong the first
  time, and are kept as warnings for the corpus: sh's `2>/dev/null`
  inside an rc command, and an unquoted `=` in an argument.

## Verification

- `make test`: the `.mli` examples, the laws, the corpus against its
  outputs recorded from 9base's rc.
- A differential script, live, against 9base's rc (and orc, for the
  record).
- The milestones, scripted: principia's scripts, the xix build, the
  interactive session.

## Out of scope

- sh, POSIX or bash compatibility: TinyRc is rc.
- Line editing, history and completion (rc has none; the terminal or
  the window system edits), job control (`^Z`, `fg`, `bg`: not in rc).
- Plan 9's namespaces on the host: `rfork n`, `bind`, `mount` do
  nothing here; on TinyKernel, later, they are real.

## Related work

In [`notes_rc_related_work.md`](../related-work/notes_rc_related_work.md).
