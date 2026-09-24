(* Three-way merge of files: principia's merge3 (9front's), which
 * git/merge runs on each file both sides changed.
 *
 * Two diffs from the base, one to each side; their changes taken in
 * base order. A change only one side made is taken; two changes whose
 * base ranges overlap are widened to the same range, and taken once if
 * their new text is the same, or else written as a conflict:
 *
 *   <<<<<<<<<< ours.c
 *   our lines
 *   ========== original
 *   the base's lines
 *   ========== theirs.c
 *   their lines
 *   >>>>>>>>>>
 *
 * (ten characters, and the base section always, where diff3 -m and
 * git write seven and no base.) One quirk is kept: the base lines
 * before a change the second side made are bounded by the first
 * side's length (the C's fetch compares its Biobuf with the first
 * diff's). *)

(* the merged text, and whether it has a conflict *)
val merge : left:Diff.file -> base:Diff.file -> right:Diff.file -> string * bool
