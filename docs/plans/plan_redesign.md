# Plan (optional, for later): redesigns, after xix and beyond

Status: **not started, optional.** Written 2026-09-24, after the
linker's rule table became one `select` per machine (commit 2a40460),
modeled on xix's `linker/Codegen5.ml`. That change taught that ix had
kept C structures (5l's optab and case numbers: a table-driven stand-in
for pattern matching) that OCaml does not need. This plan asks the same
question of every component: what in ix exists only because C lacks
ADTs and matching (tables and integer codes, flag bits, sentinel
values, strings used as types, mutable records rewritten in place,
globals)?

Sources: six read-only comparisons of ix against the author's xix
(`~/github/xix`: `builder/`, `shell/`, `editor/`, `assembler/`,
`linker/`, `compiler/`), and ideas of our own, marked **(ours)**. The
output contract is unchanged: byte-identical to 9base and goken,
checked by the tests named with each item.

Main finding: xix now helps mostly as a counterexample. ix is already
the better design in most places (see "Not to copy"), so the items
below are local redesigns, not rewrites.

## Real bugs found (fix first, whenever this plan starts)

- **rc: `exec` with only a redirection.** `rc -c 'exec >a; echo x'`:
  9base prints `rc (...): empty argument list` and exits 1; ix writes
  `x` into `a` and exits 0 (verified). Cause: a string-matched special
  case, `Redirect (r, Simple [Word ("exec", false)])` in
  `shell/Eval.ml` (~line 114), which also misses `builtin exec` and an
  `exec` held in a variable. Fix: delete the case; add a corpus case
  to `shell/tests/differential.sh`.
- **ld: DATA past its symbol is dropped silently.** `Link.data_bytes`
  (`linker/Link.ml` ~456) skips a DATA whose `a + width > data_size`,
  and it checks against the whole segment, not the symbol's size. 5l's
  dodata and xix (`linker/Layout.ml:274`, "initialize bounds") report
  it. Fix: check `off + width <= dsym.size` in `layout_data`, an error
  with the object's file.

## The toolchain (assembler, linker, compiler)

1. **Typed opcodes shared by all three tools (ours; xix types them in
   its grammar tokens).** `Arm.op`/`Arm64.op` (with `show`, `decode`)
   move from the linker into modules of `ix_asm`. The assembler decodes
   while it parses, so an unknown mnemonic is an error with file:line
   at assembly time. The compiler's backends write constructors, not
   strings: `ins "MOVW"`, `"CMN" ^ String.sub cmp 3`
   (`compiler/Emit.ml` ~144), and `(p ()).as_ <- "BGT"`
   (`compiler/Arm.ml` ~200). To decide: keep the string in the object
   (arch-neutral `Asm.obj`, about 10 lines of decode at load), or make
   the object an arch-indexed sum. Risk: none to output; golden.sh,
   libc.sh, compiler/tests/listing.sh.
2. **Suffixes decoded once (ours and both reports).**
   - arm: the condition and the S/P/W/U flags, now re-parsed from
     `suffixes : string list` by `Arm.scond` on every `view`, which
     `select` calls in layout and again in encode. A typed field set at
     load: `cond : cond option` (shared: B, conditional RET, follow's
     `ends`), and the flags. Keep 5l's "the last condition wins".
   - arm64: `MOV.W`/`MOV.P` (pre- and post-indexed) belong to the
     memory operand, as its addressing mode (`Asm.mem`), not to the
     instruction (now `List.mem "W" p.suffixes` in `Arm64.aclass`).
   - Risk: low; golden.sh, fuzz.py.
3. **Operand classes replaced by tests on values (ours; xix's
   Codegen5 does this with `immrot i`).** `aclass` computes one of 40
   classes (`cls`) and `cmp` encodes a lattice over them (and arm64
   ranks them with `Obj.magic`), which is 7l's way to ask "does this
   offset fit in 12 bits scaled by 8?". Instead, resolve an operand to
   a value (`Const n | Mem {base; off} | Addr ...`) and let `select`
   test the ranges in 7l's order (`fits_scaled12 off 3`, `immrot v`,
   `isbitcon v`). Removes `cls`, `cmp`, the rank. The riskiest item:
   the classes encode goken's exact thresholds. golden.sh, libc.sh,
   fuzz.py 5 and 7 (run several seeds).
4. **The linker's program (both reports and ours).**
   - follow (xfol): real `link` and `mark` fields (5l's), local to the
     pass, instead of ids stored in `pc` and two Hashtbls
     (`Link.follow`); `pc` then has one meaning. Or a graph built once,
     with passes returning new arrays (ours). High risk: follow decides
     every executable; golden.sh, libc.sh, fuzz.py.
   - Split the overloaded `target`: a branch's target, a load's pool
     word, a TEXT's next TEXT during follow, a BCASE's entry.
   - Factor the two machines' `layout` drivers (Func, etext,
     text_size, data_start): ~25 lines.
   - Load: `t.progs @ ...` per object is quadratic on libc.
   - Latent: arm64's condition operands (CSEL) are `Special s` like
     CPSR; a `Cond of cond` operand before CSEL is encoded.
5. **The compiler (report; xix's `Arch_compiler`/`env` as models).**
   - Emit's `prog`: a variant `Ins | Text | Data | Globl` instead of a
     mutable `as_ : string` plus a `pseudo` field saying it twice.
   - One machine description, installed once, instead of seven forward
     references (`Tree.mach`, `Emit.be`, `Gen.hooks`, `Check.xcom`,
     `Check.outstring`, `Declare.on_function`, `Declare.gextern`).
   - The statement context (`breakpc`, `continpc`, `cases`...) passed
     down instead of saved and restored in globals (`Gen.scoped`).
   - At the end of `codgen`, check that every register is free
     (xix's "reg %d left allocated"): no output change.
   - `exception Return` used as control flow in `cgen`.
   - Keep: `xcom`'s cached complexity (xix recomputes it,
     quadratically), the immutable instruction list.
   - Risk: listing.sh 5 and 7, compiler/tests/fuzz.sh.

## The shell

- `<{` and `>{` as one lexer token (rc's PIPEFD), so the parser's
  two-token lookahead (`ahead` as a list, `unread`) goes: ~10 lines.
- The global `Parser.parsers` assq list, there to carry `last_if`
  across lines: into `Lexer.t` or a parser value.
- Builtins registered in a global Hashtbl by `Builtin.init ()` to
  break the Eval/Builtin cycle: a field of `Eval.t` or a constant list.
- `Switch of word * cmd`, whose cases are found by matching the word
  "case" at each run: `Switch of word * (word list * cmd) list`, the
  printer re-emitting `{case ...}` (whatis must stay byte-identical;
  Parsecheck's print/reparse law).
- Keep: the tree-walker (not xix's bytecode VM), `Env.local` with
  Fun.protect, the hand-written parser (Parser.mli justifies it; xix's
  yacc grammar needed a global `skipnl` side channel).

## The builder

- A `Failed` build status: `Beingmade` now also means "failed forever"
  (`Build.ml` ~84, ~233, ~282).
- The shell as a value, `{ argv; kind : Rc | Sh }` with its quoting,
  separator and flags, instead of a suffix test in five places
  (`Word.quoting_of_shell` callers).
- One shared record per rule line instead of `rule.id : int` (C's
  pointer comparison); NREP keyed on it; -d p sorts by (file, line).
- One variable table with an origin and an export flag, instead of
  four Hashtbls (`vars`, `here`, `noexport`, `overridden`).
- Smaller: `work` returning its bool instead of `did : bool ref`;
  `running` computed from `slots`; the master recipe arc stored on the
  node once.
- Keep: the hand-written reader (MKSHELL changes quoting mid-file,
  backquotes run while a line is read), nodes that never change.

## The editor

Tests first: fuzz.py covers neither spaced or juxtaposed address
operands (`3 4`, `$3`, `.5`) nor the file commands (`e E f r w W !`).

- Addresses parsed into a term list, then evaluated, instead of one
  loop with refs and `raise Exit` (`Address.ml` ~52-113). Keep ed's
  quirks: `3 4` is 7, a search starts from the running value, a lone
  `+` is +1.
- The print mode (`l`, `n`) passed to the printers, not global refs
  reset in several places.
- The address range passed as a value, not `addr1`/`addr2` mutated in
  `Command.t`.
- Not: a whole-line command AST (ed's error order depends on reading
  and checking interleaved).
- Keep: the regex engine (the Pike VM gives 9base's answers), the
  line records with identity (marks, undo).

## Not to copy from xix

- rc's bytecode compiler and VM (C's code.c/exec.c layout), its
  threads and globals.
- ocamllex/ocamlyacc front ends for rc, mk, ed: their lexing depends
  on context; hand-written is justified there.
- Typed instructions per operand shape in the objects: the shape that
  decides an encoding is known only at link time.
- ed's temp file of line offsets; `Re_str` regexps (not 9base's).
- Approximations of goken: the 4000-byte pool flush, data in hash
  order without the small-first pass, loading every library member,
  forward gotos patched instead of chained, registers from R0 without
  the round robin, the `<` time test in mk.
- `Obj.magic` to pick an architecture's record.
