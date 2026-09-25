# mini-ed's corpus

A case is `case.ed`, the commands, with optionally `case.txt`, the file
to edit, `case.args`, ed's arguments, and `case.pipe`, to give the
commands through a pipe (so that an error does not end the script);
`case.out` is what 9base's ed printed and left, recorded by
`../differential.sh record`.

Where mini-ed differs from 9base's ed on purpose, `case.mini.out` is
what mini-ed must print instead (plan_ed.md, "Principles"):

- `long_line`: a line of 5,000 characters. ed.c's buffer holds 4,096
  runes a line, so 9base's ed refuses it (`?`) and its buffer stays
  empty; mini-ed has no limit.
- `global_empty`: `v/x/d` on an empty buffer. ed.c's g marks line 0,
  which is not a line, and gdelete then "deletes" it, leaving `$` at
  -1, so every command after fails; mini-ed leaves line 0 alone.
- `latin1`: a line with bytes that are not UTF-8 (Latin-1's é and à).
  9base's ed reads runes, so each such byte becomes U+FFFD and is
  written back as such (4 of the 5,720 `diff -e` replays of xix's
  history broke this way); mini-ed keeps the bytes, so a file it does
  not change comes back the same.
