# tiny/

The free variants of ix's programs, one file each: what is left of a
program when compatibility is dropped and only its idea is kept,
written after its faithful twin and from what that one taught.

| file | its twin | the idea kept |
|---|---|---|
| `builder/TinyBuildSystem.ml` | `builder/` (TinyMk, mk) | rules, `%`, stamps as digests, one pass with `-j` |
| `shell/TinyShell.ml` | `shell/` (TinyRc, rc) | lists as the only value, words joined by adjacency, redirections around the command |
| `editor/TinyEditor.ml` | `editor/` (TinyEd, ed) | sam's command language: dot a range, loops over matches, changes in parallel |

Each directory has a `test.sh`, run by `make test`; the plans'
Status logs (`docs/plans/`) tell how each was chosen and checked.
