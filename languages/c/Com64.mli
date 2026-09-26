(* 64-bit arithmetic as calls to libc, where the machine can't (com64.c):
 * on arm a vlong is a structure to 5c, and its operators, its
 * conversions and its tests are calls (_addv, _sl2v, _testv...). This
 * is the machine's convention, not 5c's code: both back ends need it,
 * compat from its xcom and simple from its hook. *)

(* the complexity of a call, the one Sethi-Ullman's order gives it *)
val fnx : int

(* n as a call to libc, when it is a vlong's operation (the machine's
 * machcap does nothing itself); None: n as it is *)
val com64 : Tree.expr -> Tree.expr option

(* a vlong tested as a condition: _testv's *)
val bool64 : Tree.expr -> Tree.expr
