# A shell, from scratch: a tutorial for `shell/`

What a shell does, and how rc does it: a line read, cut into words,
parsed into a tree, and run -- by forking processes, wiring their file
descriptors into pipes and files, and waiting for them. It is written
for **a reader of TinyRc's code, not a user of rc**, and explains the
ideas in the order the code needs them.

It is the specification of the program planned in
[`plan_rc.md`](../plans/plan_rc.md), written before the code, to be
checked against it and have its numbers measured, as
[`notes_mk.md`](notes_mk.md) was for TinyMk (which got six things
wrong, all corrected and listed in its plan). Every example below was
run on 9base's rc (`/usr/lib/plan9/bin/rc`) on 2026-09-23, unless it
says "to check". Companions:
[`notes_rc_related_work.md`](../related-work/notes_rc_related_work.md)
and the twins, the Principia book `shells/Shell.nw` (the C rc) and
xix's `shell/` (orc).

## 0. Where the code is, and a reading order

| module (`shell/`) | what | section |
|---|---|---|
| `Lexer` | characters to tokens: words, quotes, free carets, keywords | §2 |
| `Parser`, `Ast` | tokens to a tree of commands (menhir, rc's `syn.y`) | §2 |
| `Word` | a word to a list of strings: `$x`, `$#x`, `$"x`, `$x(n)`, `^` | §3 |
| `Glob` | `*`, `?`, `[...]` against the file system | §4 |
| `Process` | fork, exec, wait, `$path`; file descriptors, pipes | §5, §6 |
| `Eval` | the tree, walked: every construct's meaning | §5-§9 |
| `Env` | variables and functions, and the environment in and out | §8 |
| `Builtin` | `cd`, `exit`, `.`, `eval`, `shift`, `wait`, `whatis`, ... | §5, §8 |
| `CLI` | rcmain, `-c`, a script, the prompt | §10 |

Read §1 for the question, §2-§4 for the language, §5-§6 for how a
command runs, §7-§9 for the rest of rc, §10 for how it starts, and
§11-§13 for how TinyRc differs from its twins, how it is tested, and
what is left as exercises.

## 1. What happens when you type `ls`

The Principia book's question, and the whole shell in one trace:

```
   $ ls -l | wc -l
   read        "ls -l | wc -l\n"                           (the terminal)
   lex         ls  -l  |  wc  -l  \n
   parse       Pipe (Simple [ls; -l], Simple [wc; -l])
   evaluate    pipe()            -> fds 3 (read end), 4 (write end)
               fork() -> child 1:  dup2(4, 1); close 3, 4
                                   execve("/bin/ls", ["ls"; "-l"], env)
               fork() -> child 2:  dup2(3, 0); close 3, 4
                                   execve("/usr/bin/wc", ["wc"; "-l"], env)
               close 3, 4; wait for both
               $status = child 1's status ^ "|" ^ child 2's
   prompt      "; " again
```

Everything else a shell has is variations on this: where the words
come from (variables, globbing, a command's output), where the file
descriptors point (files, pipes, other descriptors), and which
commands run at all (`if`, `for`, `while`, `switch`, `&&`, `||`).
Two things stand out already. The shell never reads `ls`'s output:
the kernel connects the processes, and the shell only arranges it. And
**`cd` cannot be a program**: `chdir` changes the directory of the
process that calls it, and a child's `cd` would die with the child.
So `cd`, `exit`, `.`, `eval`, `shift`, `wait` are builtins -- things
the shell does to itself.

## 2. The syntax: rc's is small

A command is words, and rc's grammar has one idea per construct:

```
   simple      ls -l *.c
   redirect    cmd >file  >>file  <file  >[2]file  >[2=1]
   pipe        cmd | cmd      cmd |[2] cmd
   sequence    cmd; cmd       cmd &        (newline = ;)
   group       { cmd; cmd }   @{ cmd }     (@: in a subshell)
   logic       cmd && cmd     cmd || cmd   ! cmd
   control     if(list) cmd   if not cmd   for(x in list) cmd
               while(list) cmd   switch(word){case pat; cmd ...}
   match       ~ word pattern ...
   function    fn name { cmd }
   assignment  x=value   x=(a b c)   x=value cmd   (local to cmd)
```

`if`, `for`, `while` and `switch` take a list in parentheses, so a
condition is a command whose status is tested, with no `then`, `fi`,
`do` or `done`. That is why the grammar (`syn.y`) is 116 lines, and
why TinyRc can have it in menhir: it nests, and it has precedences
(`|` binds tighter than `&&`, which binds tighter than `;`).

The lexer has four jobs the grammar can't do, and they are why it is
written by hand (the plan's decision 2):

- **the only quote is `'`**, and `''` inside quotes is a quote;
- **free carets**: two words with nothing between them are
  concatenated, `$x.c` being `$x^.c`, and `x$y` being `x^$y`;
- **keywords only where a command starts**: `echo if` prints `if`;
- **a newline after `|`, `&&` or `||` continues the command**, and
  `if not` is read as one token.

One surprise worth knowing before writing tests: **`=` is not allowed
in an argument unless quoted**. `echo status=$status` is "token '=':
syntax error", because `=` makes an assignment; `echo status $status`
or `echo 'status='$status` is what works. (The checks for this
tutorial ran into it.)

## 3. Words, and lists of words

Every value in rc is a list of strings; there is no other type:

```
   x=(a b c)
   $x        a b c          three words, never re-split
   $#x       3              the count
   $"x       'a b c'        one word: the list joined by spaces
   $x(2)     b              a subscript; $x(2 3) is b c
   $*        the arguments; $1, $2 ... are $*(1), $*(2) ...
   x=()      the empty list: $#x is 0
```

**Concatenation distributes**, which is what makes lists useful:

```
   a^(b c)          ab ac            one with each
   (a b)^(c d)      ac bd            pairwise, lengths equal
   (a b)^(c d e)    error: "mismatched list lengths in concatenation"
   $x.o             a.o b.o c.o      a free caret: $x^.o
   x$x              xa xb xc
```

This is the opposite of mk, whose `$X.o` with `X=a b` glues `.o` to
the last word only (`a b.o`; TinyMk's tutorial, §3): two tools of the
same system, two rules, and a reason TinyRc's `Word` is not TinyMk's.

**Command substitution**, `` `{cmd} ``, runs `cmd` and splits its
output into words on the characters of `$ifs` (blank, tab, newline):
`` `{echo one two} `` is two words. An undefined variable is the empty
list, so `$nothing` is no word at all, not an empty one -- which is
why rc needs no quotes around `$x` where sh needs `"$x"`.

## 4. Globbing

After a word is expanded, its **unquoted** `*`, `?` and `[...]` match
file names:

```
   in a directory with a.c and b.c:
   *.c              a.c b.c
   '*'.c            *.c              quoted: literal
   nomatch*         nomatch*         no match: the pattern itself
```

The subtle part is "unquoted": the quoting must survive expansion, so
that `x='*'; echo $x` prints `*` without globbing (rc's rule: only
characters that appeared unquoted in the source are pattern
characters). rc marks them with a special byte as it expands; TinyRc
keeps each expanded word as pieces, each quoted or not, and `Glob`
looks only at the unquoted ones (the plan's decision 3). Matching is
by path component, `*/*.c` reading two directory levels, and the
matches are sorted.

## 5. Running a command

For a simple command, after its words are expanded:

1. **A function?** Run its body with `$*` set to the arguments (§8).
2. **A builtin?** Do it in the shell itself (§1: `cd`, `exit` ...).
3. **Otherwise a program**: search `$path` -- a list, `(. /bin)` on
   Plan 9, kept in step with `$PATH` on Unix (`path=(/bin
   /usr/lib/plan9/bin)` makes `$PATH` `/bin:/usr/lib/plan9/bin`) --
   fork, and in the child set up the redirections and `execve`. The
   shell waits, unless the command ends with `&`.

**The status** is a string, not a number: empty for success, the exit
code otherwise (`false` leaves `1`; a killed process leaves a name
for its signal, the exact form to check). `if`, `while`, `&&`, `||`
and `!` test "empty or not". A pipeline's status is its commands',
joined by `|`: `true | false` leaves `|1`, which is not empty, so
the pipeline failed.

`return` and `break` are not rc: 9base runs them as commands ("No
such file or directory"). A function ends at its closing brace, and a
loop at its list's end, or at `exit`.

## 6. File descriptors: redirections and pipes

A redirection is a file descriptor made to point somewhere, in the
child, before `execve`:

```
   cmd >f        open f for writing -> fd; dup2(fd, 1)
   cmd >>f       the same, appending
   cmd <f        open f for reading -> fd; dup2(fd, 0)
   cmd >[2]f     dup2(fd, 2): standard error to f
   cmd >[2=1]    dup2(1, 2): standard error where standard output goes
   cmd >[1=]     close fd 1
```

Order matters and is left to right: `cmd >f >[2=1]` sends both to
`f`, `cmd >[2=1] >f` sends only standard output. A pipe is `pipe()`
then two forks (§1); `cmd |[2] cmd2` connects the first command's fd 2
instead of 1. rc's here documents and pipe substitution are two more
ways to make a descriptor point somewhere (§9).

## 7. Control flow

```
   if(~ $x a*) echo match            ~: does a word match a pattern?
   if not echo no                     the previous if's condition failed
   for(i in p q) echo $i              for(i) loops over $*
   while(! test -f done) sleep 1
   switch($x){
   case a
       echo A
   case c*
       echo C                          the first matching case; no fallthrough
   }
   test -f x && echo yes || echo no
```

`~` is a builtin that sets the status: empty if the subject matches
one of the patterns (glob patterns, applied to the string, not to
files). `if not` is the one construct with memory: it runs if the
**most recent `if`** had a false condition, so it must be the next
command after that `if` -- a small piece of state the evaluator keeps
(`if(true) echo yes; if not echo no` prints `yes`).

## 8. Functions, and the environment

```
   fn f { echo in f $* }       define
   f u v w                     $* is (u v w) inside, $#* 3
   fn f                        delete
   x=(p q) echo $x             prints p q; $x is back to (a b c) after
   whatis f x                  fn f {echo in f $*}
                               x=(a b c)
```

`whatis` prints a definition as rc would read it back: the function's
body is not the text typed but the tree printed again, normalized
(`{ echo in f $* }` came back as `{echo in f $*}`). That makes a law
for the tests: print, read, print again gives the same text.

**The environment** is how a variable reaches a program: every
variable is exported, a list joined by `\001` so that a child rc
splits it back (on Plan 9 it is a file in `/env`, and the list's
elements are separated by a zero byte). **Functions are exported
too**, as `fn#f={echo in f $*}`, so `rc -c f` in a child finds `f`.
An empty list is not exported: on Plan 9 it is an empty `/env` file,
which reads back as `()`, and a Unix program given `X=` sees one empty
string -- the bug TinyMk found building xix (`ocamlc $SYSLIBS`, with
an empty argument; TinyMk's plan, phase 5).

## 9. Backquotes, here documents, pipe substitution

- `` `{cmd} `` (§3) forks `cmd` with its standard output into a pipe,
  reads it all, and splits it on `$ifs`.
- **A here document**, `cat <<EOF`, feeds the lines up to `EOF` to the
  command's standard input, with `$variables` expanded -- but not
  subscripts: `$x(1)` in a here document gives `a b c(1)`. `<<'EOF'`
  expands nothing.
- **Pipe substitution**, `cmp <{old} <{new}`, runs each command with
  its output to a pipe, and passes the pipe's name as an argument
  (`/dev/fd/N`): a way to give a program two streams where it expects
  two files. 3 of principia's scripts use it.

## 10. How rc starts

rc does not have a startup sequence written in C: it runs a script,
**rcmain** (`/rc/lib/rcmain` on Plan 9), which reads the user's
profile when asked, and then the script given, the `-c` command, or
the terminal:

```
   rc script a b        *=(a b); . rcmain; . script
   rc -c 'cmd'          . rcmain; cmd
   rc                   . rcmain; read the terminal, prompting with $prompt
```

So the interactive shell is only a script read from the terminal,
with a prompt (`$prompt`, two strings: the first for a new command,
the second for a continued line). There is no line editing and no
history: on Plan 9 the window system, rio, edits the text before rc
reads it. `^C`, on Unix, sends SIGINT to the terminal's foreground
processes: rc must not die of it while a command runs, and what it
does while reading is to check in phase 5 (on Plan 9 it is a *note*,
"interrupt", and rc can catch it with `fn sigint`).

`.` reads a file the same way, one command at a time -- which is why
a script can define a function and call it three lines later, and
why a syntax error late in a script is found only when rc gets there.

## 11. Compared with rc and orc

| | rc (C, principia) | orc (OCaml, xix) | TinyRc |
|---|---|---|---|
| lexing | hand-written | ocamllex | hand-written |
| parsing | yacc, 116 lines | ocamlyacc | menhir |
| running | compiled to code for a machine, a queue of threads | the same design | the tree, walked |
| globbing | a marker byte before unquoted metacharacters | | quoted and unquoted pieces |
| functions in the environment | yes | no | yes |
| the most common rc (the plan's 17-line check) | yes | stops at `$"x` | the goal |
| lines | 5,678 by the book's count | 2,876 | about 1,500 (target) |

The design difference is the third row (the plan's decision 1). rc
compiles a command to instructions and runs them on a queue of
"threads" -- one per nested `.` or function call -- so that the
terminal and `.` can feed the queue a line at a time, and a forked
child can go on at the right instruction. A tree-walking evaluator
in OCaml gets both from recursion and `fork`: the child evaluates the
subtree it was forked for and exits. The compiler, the instructions
and the queue, a third of the C, go.

## 12. How to know it is right

- **Differential tests**: a corpus of scripts, one per feature and
  quirk, whose stdout, stderr and exit status are recorded from
  9base's rc; TinyRc must print the same (TinyMk's method).
- **Laws**: `whatis`'s output re-reads as the same definition; a
  pipeline of n commands leaves n statuses; `{cmd}` and `@{cmd}`
  print the same when `cmd` changes no variable or directory.
- **Real scripts**: principia's, run by both shells; and the recipes
  of xix's mkfiles, run by TinyRc for TinyMk, building xix.

## 13. What's missing, and exercises

Beyond the plan's phases (in rough order of difficulty):

- **a `-n` mode** that parses and prints the tree, the way `mk -n`
  prints recipes (`Parser`, `Ast`);
- **`$status` for a killed process** in rc's words for the signal
  (`Process`, §5);
- **line editing** at the prompt, as a separate program between the
  terminal and the shell -- what rio does, and what readline does
  inside bash (§10);
- **job control** -- `^Z`, `fg`, `bg` -- which rc never had and which
  needs process groups and the terminal's foreground group (§5, §10);
- **a sh mode**: POSIX sh's word splitting, `$@` and `"..."`, on the
  same evaluator, to see how much of sh's complexity comes from
  strings where rc has lists (§3).

## 14. In ix

TinyRc is TinyMk's shell first: `MKSHELL=tinyrc`, and the two build
xix together (the plan's milestone). Later it is the shell of
TinyKernel, where `rfork`, `/env` and notes stop being no-ops, and the
first program to read `/dev/cons`. And TinyShell.ml, in `shell/tiny/`,
comes after it: one file, only what a shell is, from what TinyRc
taught.

## Glossary

- **Word**, **list**: a string, and rc's only value (§3).
- **Free caret**: the `^` rc inserts between adjacent words (§2, §3).
- **Distribution**: `^` applied pairwise, or one with each (§3).
- **Glob**, **pattern**: `*`, `?`, `[...]`, when unquoted (§4).
- **Builtin**: a command the shell runs itself, because it changes the
  shell (§1, §5).
- **Status**: a string, empty for success; a pipeline's joined by `|`
  (§5).
- **File descriptor**, **redirection**, **pipe**, `dup2` (§6).
- **Here document**, **pipe substitution**, **command substitution**
  (§9).
- **rcmain**: the script rc runs first (§10).
- **Environment**: variables and functions passed to programs (§8).

## References

- Ken Thompson, the first Unix shell, 1971 (Unix V1's `sh`).
- Stephen R. Bourne, "An Introduction to the UNIX Shell", Bell Labs,
  1978 (`principia/shells/docs/sh.pdf`).
- Tom Duff, "Rc -- The Plan 9 Shell", 1990
  (`principia/shells/docs/rc.ms`), and rc(1).
- Byron Rakitzis, rc for Unix, 1991.
- Paul Haahr and Byron Rakitzis, "Es: A shell with higher-order
  functions", USENIX Winter 1993.
- Marc J. Rochkind, *Advanced UNIX Programming*, 1985 (a mini-shell,
  explained).
- W. Richard Stevens, *Advanced Programming in the UNIX Environment*,
  1992 (fork, exec, pipes, process groups).
- François Pottier and Yann Régis-Gianas, Menhir.
- Yoann Padioleau, *Principia Softwarica: The Plan 9 Shell rc*
  (`principia/shells/Shell.nw`), and orc (`xix/shell/`).

(Dates and venues from memory unless a file is named: to check before
this note is called finished.)
