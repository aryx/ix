# Related work: version control, from SCCS to git and its clones

Where TinyGit ([`plan_vcs.md`](../plans/plan_vcs.md),
[`notes_vcs.md`](../tutorials/notes_vcs.md)) sits among the real
systems. principia's `version_control/lineage.txt` lists the family
(checked); dates and names below that are not from it or from the
code are **from memory**, marked, to check before they are quoted in a
`.mli`.

## The lineage

From principia's `lineage.txt` (checked): SCCS (1972) and RCS (1982),
one file at a time, locks; CVS (1986), many files over RCS, then
client/server (1995); Subversion (2000), CVS with atomic commits;
the proprietary line, DSEE (1984) to ClearCase (1992), Perforce
(1995), Visual SourceSafe (1994); and the distributed systems: Sun's
TeamWare (1990) and BitKeeper (2000), Arch (2001) and Bazaar (2005),
Darcs (2002), Monotone (2003), then git and Mercurial (both 2005,
after BitKeeper's license was withdrawn from Linux), Fossil (2007),
Pijul (2014). And the git clones: libgit2 (2010), dulwich (2009),
ocamlgit (2017, the author's), git9 (2021).

## The ideas, and where they came from

- **Content addressing** (from memory): Monotone named files and
  revisions by their SHA-1s before git; git took it, and Torvalds
  called git "the stupid content tracker": it records states, not
  changes, and finds renames when asked (the author's `VCS.nw`
  comments, checked, credit Graydon Hoare's monotone for the
  "SHA1 everywhere" idea).
- **Merkle trees** (Merkle, 1979, from memory): a tree whose nodes are
  named by the hash of their children's names; one hash then
  certifies everything below. git's trees and commits are one.
- **Snapshots against changes**: git, Mercurial and Subversion store
  states and compute differences; Darcs and Pijul store changes
  (patches) and a theory of how they commute, so that merging is
  better defined, at the price of speed (Darcs' "exponential merge",
  from memory). TinyVCS.ml's exercises point at the patch road.
- **Packs and deltas**: git's packs (2006, from memory) replaced one
  file per object; C git chooses deltas by a sliding window over
  objects sorted by type, name and size, with an rsync-like diff.
  git9's content-defined chunking (a gear rolling hash) is the
  technique of deduplicating stores: LBFS (Muthitacharoen, Chen and
  Mazières, SOSP 2001, from memory) introduced content-defined chunks
  with Rabin fingerprints; FastCDC (Xia et al., USENIX ATC 2016, from
  memory) the gear hash.

## Diff and merge

- **Hunt and McIlroy (1976)**, "An Algorithm for Differential File
  Comparison" (Bell Labs CSTR 41, from memory): Unix diff, the
  candidate method principia's diffreg.c credits to Harold Stone.
- **Myers (1986)**, "An O(ND) Difference Algorithm and Its Variations"
  (Algorithmica, from memory): the shortest edit script, what GNU diff
  and C git use; xix's ogit ported it (`diff_myers.ml`).
- **diff3** (Randy Smith, 1988, from memory) and **Khanna, Kunal and
  Pierce (2007)**, "A Formal Investigation of Diff3" (FSTTCS; ogit's
  `diff3.ml` cites it): merge3 is diff3's algorithm; its markers are
  git9's own (ten characters, the base always shown).

## The git implementations

- **C git** (Torvalds, 2005; Hamano since): the reference. What git9,
  and TinyGit, leave out: the binary index, packed-refs writing,
  protocol v2, thin packs, OFS deltas on write, commit-graph,
  multi-pack index, submodules, hooks, rename detection, rebase with
  a sequencer, and much more.
- **dulwich** (Jelmer Vernooij, Python, from memory 2008-9) and
  **ocaml-git** (Thomas Gazagnaire, from memory 2013): the author's
  earlier books followed dulwich, and xix's ogit took parts of
  ocaml-git (checked, in its headers). ogit has loose objects only.
- **git9** (Ori Bernstein, 9front, from memory 2019-21): the twin. Its
  ideas worth keeping: the repository as a file system (git/fs), so
  scripts use `cat` and `cp` on history; a text staging file; commands
  as small scripts over a few programs; the revision language as a
  stack machine with `@` for the common ancestor.

## Where TinyGit sits

A twin of git9, in OCaml, for Linux: git9's behaviour where git9 has
one (its commands, their outputs, INDEX9, the query language, merge3),
C git's bytes everywhere (the same object hashes, packs `git
verify-pack` accepts, the protocol `git daemon` speaks). The free
variant, `tiny/TinyVCS.ml`, is where a different design goes.
