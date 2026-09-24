# Plan: TinyGit, git9 in OCaml, and its diff (`version_control/`)

Companions, to write with the code as for TinyDb: `notes_vcs.md`, the
tutorial (content-addressed objects, trees as Merkle trees, commits as
a DAG, the staging file, packs and deltas, the wire protocol, three-way
merge), and `notes_vcs_related_work.md` (SCCS and RCS to CVS and
Subversion, BitKeeper, Monotone and git, Mercurial, Darcs and Pijul,
and the git clones: dulwich, ocaml-git, libgit2, git9; principia's
`version_control/lineage.txt` lists them).

The twin is git9, Ori Bernstein's git for Plan 9 (9front), in
principia's `version_control/git9` (the author's book on it,
`VCS.nw`, replaced his earlier dulwich and ocamlgit books in 2026 "to
be more consistent with the other principia books"), with the diff
and merge3 it calls, `version_control/diff`. Counted without the
literate chunk markers: 7,912 lines of C in git9 (pack.c 1,716, fs.c
873, walk 575, ref 565, serve 563, proto 522, util 488, get 481, save
464, git.h 325, log 286, send 261, delta 200, query 197, ols 156,
conf 100, repack 78, objset 62), 1,406 of rc scripts (the commands:
add, commit, branch, merge, pull, push, clone, ...), and 1,309 in
diff and merge3. xix's twin is ogit (`~/github/xix/vcs`, 5,429
lines, from dulwich): loose objects only, no packs, no network, no
merge; read, not followed (principle 2).

The seventh ix program. The author chose it ("let's to tiny git (see
the code of git9 in ~/principia, or ocamlgit in ~/xix, and more) and
then the freeform TinyVCS.ml!").

## Context

A version control system keeps every version of a tree of files, and
lets several people change it at once and combine their changes. git
does it with three ideas: an object is named by the hash of its
content (so equal content is stored once, and a name is a checksum);
a directory is a tree object listing its entries' names, so a commit's
hash names its whole tree and history (a Merkle tree, and a DAG of
commits); and a branch is a file holding a commit's hash. Everything
else -- the staging area, packs, deltas, the protocol, merge -- is
built on those three.

git9 is git reduced to what Plan 9 needed: the same repository format
(a git9 repository is a git repository, and git9 clones from GitHub),
with the commands as rc scripts over a handful of C programs, and the
repository served as a file system (`git/fs`, 9P): a commit is a
directory with `tree/`, `parent`, `msg`, `author`, so the scripts use
`cp`, `cat`, `diff` and `walk` on history. Its staging file, INDEX9,
is text, not git's binary index.

Why git now:

- **The format is the contract, and C git runs.** git9 does not run on
  Linux (its programs need Plan 9's libsec and a 9P mount; goken has
  neither), but git9 writes git's format, so C git 2.43
  (`/usr/bin/git`) is the reference for everything on disk and on the
  wire: an object's hash is the same or it is wrong, a pack is one
  `git verify-pack` accepts, a push is one `git receive-pack` takes.
  `git daemon`, `git upload-pack`, `git receive-pack` are installed,
  so the protocol is testable locally, both ways.
- **Where git9's own behaviour is the spec** (its command outputs,
  INDEX9, the query language, merge3's markers), it is read from the
  C, and checked by git9's own tests (`git9/test/*.rc`, translated to
  sh) and principia's diff corpus (`diff/test/`: 15 diff cases and 13
  merge cases with expected outputs). 9base's diff (`/usr/lib/plan9/bin/diff`)
  is the same algorithm (Hunt and McIlroy's, "due to Harold Stone"),
  older, without `-u`: it runs, for the other formats.
- **It teaches what the others did not**: hashing as naming, a
  persistent data structure on disk (TinyDatabase.ml's copy-on-write
  tree is a git tree), compression, deltas, a network protocol, and
  three-way merge.
- **principle 12 has much to do**: git9's objects are a struct with a
  type int and a union of commit/tree fields filled in by flags
  (`Cloaded`, `Cparsed`), a delta is `{cpy; off; len}`, the protocol's
  connection an int, INDEX9's states chars.

## Principles

Those of [`../README.md`](../README.md), and three of its own:

- **Two references, split by what they know.** C git for bytes (objects,
  packs, refs, the protocol); git9's C for behaviour (commands, their
  outputs, INDEX9, the query language, merge). The first is run, the
  second read (principle 3's "the program is the specification" --
  here the program is read, since it cannot be run; said so).
- **Every object hash equal to C git's.** The same edits committed by
  tinygit and by `git commit` (with the same author, dates and
  message) give the same commit hash; git9 writes the timezone as
  `+0000`, so the tests set `GIT_*_DATE="N +0000"`.
- **C git reads everything tinygit writes, and the reverse**:
  `git fsck --strict` on every repository a test leaves, and tinygit
  reading repositories made, packed and served by C git.

## The interface: git9's commands, as one executable

`tinygit CMD args`, where git9 has `git/CMD` (a directory of programs
on Plan 9's `$path`); the flags and outputs are git9's.

| git9 | what | TinyGit |
|---|---|---|
| `init [-u url] [-b branch]` | a repository | kept; `repositoryformatversion = 0`, not git9's `p9.0`, which C git refuses (deliberate difference 1) |
| `add [-r]`, `rm` | lines appended to `.git/INDEX9` | kept |
| `commit [-m msg] [-r]`, `save` | the tree from the files, the commit, the branch | kept; `-e` (the editor) kept through `$EDITOR`; `-p` (hunk picking, interactive, through patch and /dev/cons) dropped |
| `walk [-qcfbI...]` | status: `A M R U` against HEAD's tree | kept; INDEX9's qid is a stat fingerprint (decision 5) |
| `diff [-c] [-s] [-u]` | `diff -u` of each changed file | kept, through TinyDiff (decision 8) |
| `log [-s] [-n] [-c] [-e expr] [files]` | history, by commit time | kept, dates in GMT |
| `query [-cpr] expr` | the revision language: `^ ~ @ .. :` | kept (decision 6) |
| `branch [-abrnsmM]` | list, create, switch, merging dirty files | kept |
| `merge`, `revert` | three-way merge by merge3; files back from a commit | kept |
| `get`, `clone`, `pull` | fetch: git://, ssh, local, smart http(s) | kept but http(s) (decision 9) |
| `send`, `push` | push, fast-forward only unless `-f` | kept |
| `serve [-w] [-r]` | the server side, on stdin/stdout | kept |
| `repack` | all objects into one pack | kept |
| `conf [-ra] [-f]` | `.git/config` lookups | kept |
| `fs` | the repository as a 9P file system | replaced by `tinygit fs PATH`, the same paths read without a mount (decision 4) |
| `export`, `import`, `rebase`, `hist` | patches by mail, and what is built on them | later, with a patch (phase 9) |
| `compat` | a `git` command for Go's tools | dropped |

And `tinydiff` and `tinymerge3`, principia's `diff` and `merge3`.

## Target layout

```
lib_security/Sha1.ml(i)      SHA-1 (principia's libsec)          done
lib_compression/Zlib.ml(i)   inflate, deflate (libflate)          done
version_control/             library ix_vcs; tinygit, tinydiff, tinymerge3
  Hash.ml(i)                 20 bytes, hex, the zero hash
  Object.ml(i)               Blob | Tree | Commit | Tag, parsed and
                             printed; tree order (entcmp)
  Loose.ml(i)                .git/objects/xx/yyyy, zlib'd
  Pack.ml(i)                 .pack and .idx v2: read, deltas, index a
                             received pack, write one
  Delta.ml(i)                apply; encode by gear chunking (git9's)
  Store.ml(i)                objects by hash: cache, packs, loose;
                             abbreviations
  Refs.ml(i)                 HEAD, refs/..., symbolic refs; packed-refs
                             read (deliberate difference 2)
  Conf.ml(i)                 git9's line matcher over .git/config
  Query.ml(i)                the revision language; paint (LCA, ranges)
  Index9.ml(i)               INDEX9 read, merged, written
  Walk.ml(i)                 status against a tree
  Save.ml(i)                 treeify, the commit
  Log.ml(i)                  history, its path filter
  Fs.ml(i)                   git/fs's paths, resolved
  Pktline.ml(i), Proto.ml(i) pkt-lines; transports; capabilities
  Get.ml(i), Send.ml(i), Serve.ml(i)
  Diff.ml(i)                 Stone's algorithm (diffreg.c), the formats
  Merge3.ml(i)               three-way merge of files
  Commands.ml(i)             the rc scripts: init, add, commit, branch,
                             merge, pull, push, clone, revert, diff
  CLI.ml(i), Main*.ml
version_control/tests/       Testo, the differential scripts, the
                             translated git9 tests, a fuzzer
tiny/TinyVCS.ml              the free variant (see "Outside git9")
```

**The size target**, by module: Hash 30, Object 200, Loose 40, Pack
450, Delta 120, Store 90, Refs 100, Conf 50, Query 200, Index9 70,
Walk 200, Save 140, Log 110, Fs 130, Pktline+Proto 250, Get 160, Send
90, Serve 200, Diff 350, Merge3 120, Commands 550, CLI+Main 100:
about **3,600 lines of OCaml**, a third of what it twins (7,912 +
1,406 + 1,309). Sha1 (61) and Zlib (230) are counted apart, as
libraries.

## Groundwork decisions

### 1. SHA-1 and zlib are ours, in libraries of their own

git9 takes them from libsec and libflate, principia libraries; ogit
took an inflate from extlib and C's libz through camlzip. Here they
are written from the RFCs (61 and 230 lines), in `lib_security/` and
`lib_compression/`, principia's library names, since TinyVCS.ml will
use them too. Deflate writes fixed-code blocks only, with greedy LZ77:
git reads any stream, and a hash is over the uncompressed bytes, so a
repository is the same whatever the compression; compressed files
are not compared. Checked: 200 random inputs against Python's hashlib
and zlib (every level, bytes after the stream), `lib_compression/tests/check.py`.

### 2. An object is a variant; parsing is one function, printing its inverse

```ocaml
type t =
  | Blob of string
  | Tree of entry list            (* {mode : mode; name; hash} *)
  | Commit of commit              (* {tree; parents; author; committer; msg} *)
  | Tag of string                 (* kept raw, as git9 does *)
and mode = File | Exec | Dir | Link | Submodule
```

git9's `Object` is one struct for all types, with the commit and tree
fields valid after the `Cparsed` flag, and cached with reference
counts; in OCaml an object read is immutable, so the cache is a
table by hash, bounded (git9's LRU, 128 MiB). `print (parse s) = s`
is a law, tested on every object of a real repository (git9's
`gpgsig` drop is where parse loses: kept in a `extra` field instead,
so the law holds; deliberate difference 3, invisible in the outputs).

### 3. Packs: read everything C git writes; write what git9 writes

Reading: `.idx` v2, pack v2, both delta kinds (OFS and REF), as git9.
Writing (repack, a push, a received pack's index): pack v2 with
REF_DELTA only, git9's gear-hash chunking for deltas (window 10,
chains up to 128), `.idx` v2. The index of a received pack is built
as git9 builds it: passes until every delta's base is known. Checked
by `git verify-pack` and `git fsck`, not by bytes (a pack's bytes
depend on the deflater).

### 4. git/fs becomes a resolver, and the scripts read it directly

The scripts read history through `.git/fs/`: `$gitfs/HEAD/tree/f`,
`object/H/parent`, `branch/heads/x/tree`. A 9P or FUSE server on
Linux is a lot of machinery for a namespace nothing else needs to
mount; the paths are kept (`Fs.resolve : string -> File of string |
Dir of string list`, and `tinygit fs PATH` prints one), and the
commands, being OCaml, call it rather than a mounted file. Where a
script copied a tree out of the file system (`cp`, `tar`), the command
writes the tree's blobs.

### 5. INDEX9 keeps its lines; its qid is a stat fingerprint

`STATE QID MODE PATH` (`A` added, `R` removed, `T` tracked, `U`
dropped on rewrite), the last line of a path winning, appended by
`add` and rewritten by `walk`. A Plan 9 qid (path, version, type)
changes when a file does; on Linux its stand-in is
`inode.mtime_ns.size` in hex, `NOQID` kept for "compare the bytes". A
state is a variant, `Added | Removed | Tracked | Untracked`, printed
as its letter.

### 6. The query language: a stack machine over a small grammar

`postfix+ | postfix (".." | ":") postfix`, a postfix a word followed by
`^` or `~` (first parent, identical) and `@` (pops two, pushes their
lowest common ancestor). git9's `paint` colours from heads and tails
through a max-heap on commit time until the heap is empty; its tie
order is observable (the range tests), so the heap is git9's binary
heap, not a `Set`. Times are git9's: epoch plus the timezone's offset.
Checked against `git merge-base` (as sets: git9 picks one LCA of
several) and `git rev-list` (sets; order on dates without ties).

### 7. The commands are OCaml, following the rc scripts line for line

The scripts depend on Plan 9's `walk`, `cleanname`, `bind`, `ramfs`,
`rfork`, `/env`, and git/fs's mount; ported to sh they would need
those too. So each script is a function in `Commands.ml`, in the
script's order, with its messages and exit statuses (walk's status
is its dirty letters, `RMAU`; a failure is exit 1 with the letters on
stderr, as rc's non-empty status becomes).

### 8. diff and merge3 are principia's, and TinyDiff is their twin

git9 calls `diff -u` and `merge3`; principia's are 9front's (Stone's
algorithm with line hashing, `-u`, "\ No newline at end of file",
merge3's ten-character markers with the base section). Ported
faithfully as `Diff` and `Merge3`, with `tinydiff` and `tinymerge3`:
the diff corpus (`diff/test/`, 28 cases) must pass, and every format
9base's diff has (`-e -f -n -c -a`, the default) is compared with it
on random files. patch (767 lines) waits for phase 9.

### 9. Transports: git://, ssh, local; http later

git9 dials `git://` (TCP), `ssh` (`/bin/ssh host git-upload-pack
path`), a local path (its own `serve` over a pipe), and http(s)
through Plan 9's webfs. OCaml has no TLS in the standard library;
smart http without TLS is testable (`git http-backend` through a
small CGI runner) but GitHub is https. So http is phase 8b, through
`curl` as a child process standing in for webfs, if the author wants
it.

## Deliberate differences

1. `repositoryformatversion = 0`, not `p9.0` (C git refuses p9.0).
2. `packed-refs` is read (git9 does not; C git writes it on clone and
   gc, and the tests read C git's repositories).
3. A commit's headers git9 does not know (`gpgsig`, `encoding`) are
   kept for printing, not dropped.
4. Dates print in GMT (git9 prints Plan 9's `ctime` in the machine's
   zone).
5. `commit` takes its date from `GIT_AUTHOR_DATE` when set, as C git
   does (git9's `save -d` exists, but `commit.rc` does not pass it):
   the tests' way to make both give the same hash.
6. `walk` counts a path as checked in only if it is a *file* of the
   commit. git9 tests it with `access()` in `HEAD/tree`, which a
   directory passes: after a file becomes a directory, `commit.rc`
   leaves a `T` line for the old file path, every later `walk`
   reports it `R`, and the next commit removes the whole directory
   (found by `session.py`; git9's own tests commit only once after the
   change).

Each with a test case of its own.

## Phases

1. SHA-1 and zlib (done: `lib_security/`, `lib_compression/`).
2. Hash, Object, Loose, Store: `tinygit cat`-style checks, every
   object of a C git repository read and re-hashed; `print . parse`.
3. Pack and Delta, read: every object of a `git gc`'d repository
   (OFS deltas) and of a `git repack --no-delta-base-offset` one.
4. Refs, Conf, Query, Log, Fs: against `git rev-parse`, `merge-base`,
   `rev-list` on random DAGs built by C git.
5. Index9, Walk, Save and the local commands (init, add, rm, commit,
   branch, revert, diff -s): the same random sessions through tinygit
   and C git, commit hashes equal; `git fsck --strict`.
6. Diff and Merge3, `diff`, `merge`: principia's corpus, 9base's diff,
   git9's merge tests.
7. Pack writing, `repack`: `git verify-pack`, `fsck`.
8. The protocol: `get`/`clone`/`pull` from `git daemon` and a local
   repository; `send`/`push` into `git receive-pack`; `serve` to C git
   (`git clone ext::`); git9's tests (basic, ftype, merge, noam, range,
   lca, add, diff) translated to sh. 8b: http through curl.
9. Later: patch, export, import, rebase, hist.
10. `tiny/TinyVCS.ml`.

## Outside git9: TinyVCS.ml

Free, in one file, with Sha1 and Zlib from the libraries. Candidates,
to choose when written: git's object model kept (it is the idea), its
formats not (objects as marshalled values in one file, as
TinyDatabase.ml's nodes); the staging area dropped (commit what
changed, as Mercurial and jj do); merge by diff3 on lines; history as
the only index. Checked by its own laws: checkout of any commit
restores its tree; merge is symmetric; a clone has the same hashes.

## Verification

`make test` runs the Testo suite and the local differential scripts;
`make test-git` the network ones (a `git daemon` on a free port).

## Status

2026-09-24: plan written; phase 1 done.
