# Version control, from scratch: a tutorial for `version_control/`

What a version control system does, and how git9 (Plan 9's git) does
it: objects named by their hashes, trees and commits built from them,
references, a staging file, commits made from the work tree, packs and
deltas, the wire protocol, and the diff and three-way merge the
commands use. It is written for **a reader of TinyGit's code, not a
user of git**, and follows the code bottom up.

The program is planned in [`plan_vcs.md`](../plans/plan_vcs.md);
related systems are in
[`notes_vcs_related_work.md`](../related-work/notes_vcs_related_work.md).
The twin is git9's C and rc in principia's `version_control/git9`,
and its `diff/`. Every example below was run with tinygit, and C git
2.43 where it says so, on 2026-09-24.

## 0. Where the code is, and a reading order

| module (`version_control/`) | what | section |
|---|---|---|
| `lib_security/Sha1`, `lib_compression/Zlib` | the hash; deflate, inflate, CRC-32 | §2 |
| `Hash`, `Object`, `Loose`, `Store` | objects: named, parsed, stored | §2, §3 |
| `Refs`, `Query`, `Log`, `Fs` | names; the revision language; history | §4 |
| `Index9`, `Walk` | the staging file; status | §5 |
| `Save` | a commit from the work tree | §6 |
| `Delta`, `Pack`, `Packer` | packs and deltas | §7 |
| `Proto`, `Get`, `Send`, `Serve` | the protocol | §8 |
| `Diff`, `Merge3`, `Difftool` | diff and merge3 | §9 |
| `Commands`, `CLI` | the rc scripts: init, add, commit, branch, merge, clone, pull, push | §10 |

## 1. What version control is

```
   $ tinygit init
   $ echo hello > hello.txt; mkdir lib; echo 'let x = 1' > lib/a.ml
   $ tinygit add hello.txt lib
   $ tinygit walk
   A hello.txt
   A lib/a.ml
   $ tinygit commit -m first .
   heads/master: 71abf094a75033bef182f413614a3d080801f5dd
   $ echo 'hello world' > hello.txt
   $ tinygit walk
   M hello.txt
   T lib/a.ml
   $ tinygit commit -m second .
   heads/master: 94c0224253c29d59002347c8008d25122b12ac04
```

A version control system keeps every version of a tree of files, and
lets people change copies of it apart and combine their changes. git's
design rests on three ideas, and the rest is built on them:

1. **An object is named by the hash of its content.** Equal contents
   have one name wherever they are; a name is a checksum; nothing
   named can change.
2. **A directory is an object listing its entries' names and hashes**,
   and a commit names a tree and its parent commits: so one hash names
   a whole tree and its whole history (a Merkle tree, and a DAG of
   commits).
3. **A branch is a file holding a commit's hash.** Committing writes
   new objects and moves that one name.

## 2. Objects: hashes and zlib

An object is `KIND SIZE\0CONTENT`, named by the SHA-1 of exactly those
bytes. `hello\n` as a blob:

```
   "blob 6\000hello\n"  --SHA-1-->  ce013625030ba8dba906f756967f9e9ca394464a
```

(what `git hash-object` says too). SHA-1 (`lib_security/Sha1`) is 80
rounds over 64-byte blocks, 51 lines; it is broken for collisions, and
git keeps it, hardened.

A loose object is a file, `.git/objects/ce/013625...`, holding those
bytes deflated. Deflate (`lib_compression/Zlib`, RFC 1951) is LZ77 --
"copy N bytes from D back" -- with Huffman codes for the literals,
lengths and distances. TinyGit's inflate reads the three kinds of
block (stored, fixed codes, dynamic codes); its deflate writes fixed
codes only. The compressed bytes are not the ones C git writes, and
need not be: a name is the hash of the *uncompressed* bytes, so two
compressors make the same repository. Inflate must say where its
stream ended, for §7: a pack's objects are zlib streams laid end to
end, with no lengths between them.

`Object.t` is a variant, `Blob | Tree | Commit | Tag`, and
`print (parse k s) = s` is the law that keeps it honest: every object
of ix's, xix's and principia's histories (65,234) parses and prints
back to the bytes C git wrote.

## 3. Trees and commits

The tree of the first commit, as C git shows it, and its bytes:

```
   100644 blob ce013625030ba8dba906f756967f9e9ca394464a    hello.txt
   040000 tree 140f2984b0ed6b2f1b6c89aee20a4c070ae76ea4    lib

   "100644 hello.txt\000" + 20 bytes, "40000 lib\000" + 20 bytes
```

An entry is a mode, a name, and the 20 raw bytes of a hash. The modes
are few (`Object.mode`: `File | Exec | Dir | Link | Submodule`), and
the entries are sorted -- with a twist: a directory sorts as if its
name ended with `/`, so `a.c < a/ < a0`. git9's `entcmp` has it, and
one more twist the tests found: a file `a` and a directory `a` are
*not* equal, the file first. A port that made them equal lost a
directory's files when a branch switch turned a file into a
directory.

The commit:

```
   tree 2360de4acf7d331907ed41cf21361f358e1e0c3c
   author Glenda <glenda@9front.org> 1600000000 +0000
   committer Glenda <glenda@9front.org> 1600000000 +0000

   first
```

and the second one adds `parent 71abf094...`. git9 writes the zone as
`+0000` always. With the same author, date and message, tinygit and
`git commit` make the same commit hash: the test that holds the whole
format together (`session.py`, 200 random sessions).

## 4. Names: references and the revision language

`.git/HEAD` holds `ref: refs/heads/master`; that file holds a hash.
`Refs.read` looks a name up as git9 does: as given, then under
`refs/`, `refs/heads/`, `refs/remotes/`, `refs/tags/`, then as an
abbreviated hash (C git's `packed-refs` read too, deliberately).

git9's revision language is a stack machine: a word pushes its
object, `^` or `~` replaces the top by its first parent, `@` pops two
and pushes their lowest common ancestor, and `a..b` is what `b`
reaches and `a` does not, oldest first:

```
   $ tinygit query HEAD~ HEAD @
   71abf094a75033bef182f413614a3d080801f5dd
   $ tinygit query -c HEAD~ HEAD
   @ hello.txt
```

All three history questions are one walk, `paint`: commits taken
newest first from a max-heap on commit time, each coloured *keep*
(reached from the heads) or *drop* (from the tails), a commit reached
by both turning *skip*, and skip spreading to its ancestors. The
common ancestors are keep and drop and not skip; the range is keep
and nothing else. The walk trusts time: a parent older than its
child. The heap and the sets are git9's own, ported as they are,
since their order is visible -- which of several common ancestors is
"the" one, and the order of a range among commits of equal times
(git9's `range.rc` test depends on it).

`log` walks the same heap from one commit. With paths, it shows a
commit when what the paths name differs from a parent's, comparing
hashes down a filter tree and reading only subtrees that differ: a
Merkle tree's gift.

git9 serves all this as a file system, `git/fs`: a commit is a
directory with `tree/`, `parent`, `msg`, `hash`, `author`, so its
scripts read history with `cat` and `cp`. `Fs` keeps the paths
without the mount:

```
   $ tinygit fs HEAD
   tree/
   parent
   msg
   hash
   author
   $ tinygit fs HEAD/parent
   71abf094a75033bef182f413614a3d080801f5dd
```

## 5. The staging file, and status

git keeps a binary index; git9 keeps `.git/INDEX9`, text, a line a
path, the last line of a path winning:

```
   A NOQID 0 hello.txt          (git/add)
   A NOQID 0 lib/a.ml
   T NOQID 0 hello.txt          (after the commit)
   T NOQID 0 lib/a.ml
```

`walk` answers "what changed": it merges two sorted lists, the index
and the files on disk, against HEAD's tree. `A` added, `R` removed,
`M` modified, `T` the same. To know a file is unchanged without
reading it, the index keeps a fingerprint -- on Plan 9 a qid, which
changes when the file does; on Linux the inode, the time and the size
-- and a file that reads the same as the commit's gets its
fingerprint recorded. A file changed twice in one clock tick keeps its
time, so a file changed in the last two seconds is not fingerprinted
(git's "racy index" problem, and its answer).

Two quirks to know. With `-b`, or no INDEX9, the "index" is the
commit's own files. And git9 counts a path as in the commit if
`access()` finds it there, a directory included: a stale line for a
file that became a directory then read as its removal, and the next
commit dropped the directory. TinyGit counts files only (deliberate
difference 6).

## 6. A commit from the work tree

`save` changes only the paths it is given in HEAD's tree:

```
   path gone from disk                     -> removed
   a file, tracked (not R in INDEX9)       -> its blob
   a directory where a tracked file was    -> removed
   a directory on the way to other paths   -> its tree, recursively;
                                              removed if left empty
```

Every other subtree is kept by its hash, untouched: a new commit
shares all it did not change with its parent, as a persistent data
structure does (`tiny/TinyDatabase.ml`'s copy-on-write B-tree is the
same idea for a database). A commit is then O(changed paths × depth)
new objects, whatever the size of the tree.

## 7. Packs and deltas

Loose objects are one file each, compressed alone. A pack is many
objects in one file, most stored as a delta against another:

```
   .pack: "PACK" | 2 | count | entries | SHA-1
   entry: type and size | [base offset or hash] | zlib stream
   .idx:  "\377tOc" | 2 | fanout[256] | hashes | CRCs | offsets | SHA-1s
```

`fanout[b]` counts the hashes whose first byte is at most `b`, so a
lookup is a binary search in a 256th of the table. A delta is copies
from the base and inserted bytes:

```
   base "hello world", target "hello there":
   0b 0b | 90 06 | 05 't' 'h' 'e' 'r' 'e'
   sizes   copy 6  insert 5
```

(`Delta.op = Copy of {off; len} | Insert of string`). git9 finds
deltas by **content-defined chunking**: both objects are cut into
chunks of 128 to 8,192 bytes where a gear rolling hash has its low 8
bits zero, so a boundary depends only on nearby bytes and an insertion
moves only the chunks around it; each chunk of the target found among
the base's becomes a copy, stretched as far as the bytes keep
matching. Which objects to try: sorted by kind, by a hash of their
path, by date, each tried against the ten before it -- the versions of
one file end up side by side. C git's packs use OFS deltas (the base
by its distance back); git9 writes REF deltas (the base by its hash),
and reads both. Indexing a received pack resolves deltas in passes
until every object is known.

## 8. The wire protocol

Everything is pkt-lines: four hex digits of length, the bytes; `0000`
ends a list. A fetch:

```
   server: 1f7a... HEAD\0multi_ack side-band-64k symref=HEAD:refs/heads/master
           1f7a... refs/heads/master
           0000
   client: want 1f7a... multi_ack side-band-64k
           0000
           have 0e4c...
           done
   server: ACK 0e4c...
           [the pack, in side-band packets: band 1 data, band 2 progress]
```

The *haves* tell the server what not to send: git9 sends its copies of
the server's branches, then their ancestors newest first, up to 256.
The server packs what the wants reach and the haves do not -- `paint`
again. A push is the reverse: `OLD NEW REF` lines, then a pack, and a
push that is not a fast-forward is refused unless forced. The
transports only carry the bytes: a local repository (a `serve`
process on a socketpair), TCP for `git://`, `ssh`.

## 9. diff and merge3

diff finds a longest common subsequence of lines, by Harold Stone's
algorithm (Hunt and McIlroy's diff): lines hashed, the common prefix and
suffix set aside, the second file's lines sorted into classes of equal
hashes; then a walk over the first file keeps, for each length k, the
common subsequence of length k that ends earliest in the second file,
found by binary search, and chains back from the longest. A match the
hash made up is broken by comparing the lines. The result is J, the
line of the second file each line of the first matches, from which
every output format is printed:

```
   $ tinygit diff
   diff 94c0224253c29d59002347c8008d25122b12ac04 uncommitted
   --- a/lib/a.ml
   +++ b/lib/a.ml
   @@ -1,1 +1,2 @@
    let x = 1
   +extra
```

merge3 diffs the base against each side and walks both change lists in
base order: a change one side made is taken; changes whose base
ranges overlap are widened to the same range and taken once if equal,
else written as a conflict with the base in the middle:

```
   $ tinymerge3 ours.ml base.ml theirs.ml
   <<<<<<<<<< ours.ml
   let x = 10
   ========== original
   let x = 1
   ========== theirs.ml
   let x = 100
   >>>>>>>>>>
   let y = 2
   let z = 30
```

These are principia's own diff and merge3, run on Linux by building
their C with goken (`tests/build_plan9_diff.sh`) -- the reference that
found two behaviours no reading would have: a NUL in a line cuts it
(C's `%s`), and the "binary files differ" message jumps ahead of
buffered output.

## 10. The commands

git9's commands are rc scripts over the C programs: `commit.rc` runs
`git/walk` for the changed files, `git/save` for the commit, writes the
hash into the branch's file, and appends `T` lines to INDEX9. `branch`
copies the files that differ from the target commit out of git/fs,
merging any the user changed; `merge` is `merge3` on each file both
sides changed, and a commit later with two parents; `pull` is `get`
and a fast-forward, or "diverged"; `clone` is `init`, `get`, and a
checkout. In TinyGit each script is an OCaml function in `Commands`,
in the script's order, calling `Walk`, `Save`, `Query` rather than
programs.

## 11. How TinyGit differs from git9

Deliberately, each with a test: `repositoryformatversion = 0` (C git
refuses git9's `p9.0`); `packed-refs` read; a commit's unknown headers
kept; dates in GMT; `GIT_AUTHOR_DATE` for the tests; `walk` counting
only files as checked in. Not kept: `commit -p` (interactive hunks),
http(s), `export`/`import`/`rebase`/`hist` (they need patch), `compat`.

## 12. How it is tested

C git is the reference for bytes and git9's code for behaviour
(`plan_vcs.md`'s Status has the counts): objects read against `git
cat-file`; repacks checked by `git verify-pack` and `fsck`; the
revision language against `merge-base` and `rev-list`; random editing
sessions committed by both, hashes equal; the protocol both ways
against `git daemon`, ssh and `ext::`; principia's diff and merge3
built by goken, byte for byte; and git9's own test scripts, translated
to bash.

## 13. Exercises

- Replace SHA-1 by SHA-256 (git's `objectformat = sha256`): what must
  change besides the hash's length?
- Write deflate's dynamic Huffman blocks; measure the packs against
  fixed codes.
- `paint` trusts commit times. Build a history where a parent is newer
  than its child and find the wrong answer; then fix it with
  generation numbers (C git's commit-graph).
- Write OFS deltas in `Packer` (git9 has the code, `odelta`, unused).
- Add http(s) through `curl`, as git9 used webfs.
- Port `patch.c`, then `export` and `import`.
- Rename detection: in `query -c`, pair a removed path and an added one
  with the same blob hash.
