(* Declarations, as the parser meets them (dcl.c): a declarator's type
 * built from the words before it, a symbol's class and offset (a frame's
 * autos and parameters, a structure's fields), initializers made into
 * data, and C's scopes.
 *
 * The scopes: a symbol holds its current meaning, and a block's
 * declarations push what they hide on a stack of [undo]; the end of the
 * block ([revertdcl]) pops back to its [Mark], restoring each. The stack
 * is a list of variants, where 5c's is a list of Decl records with a
 * kind field.
 *
 * References: Ken Thompson, "Plan 9 C Compilers", section "Parsing":
 * "Declarations are interpreted immediately, building a block
 * structured symbol table"; H. G. Baker, "Shallow binding in Lisp 1.5"
 * (CACM 21(7), 1978): the same trick at run time, a value cell holding
 * the current binding and a stack of the shadowed ones -- here the
 * symbol's fields and [undo]. *)

(* a function's name and its body, parsed: to the code generator *)
val on_function : (Tree.node -> Tree.node -> unit) ref

(* the back end's, set by Gen: an initializer's data (swt.c's gextern) *)
val gextern : (Tree.sym -> Tree.node -> int -> int -> unit) ref

val stkoff : int ref

val autobn : int ref

val lastdcl : Tree.typ option ref

val lasttype : Tree.typ option ref

val lastclass : Tree.cls ref

val lastfield : int ref

val strf : Tree.typ option ref

val strl : Tree.typ option ref

val taggen : int ref

val firstarg : Tree.sym option ref

val firstargtype : Tree.typ option ref

val thisfn : Tree.typ option ref

val en_tenum : Tree.typ option ref

val en_cenum : Tree.typ option ref

type undo =
    Mark of int * int
  | Name of Tree.sym * Tree.typ option * Tree.cls * 
      int * int * bool
  | Tag of Tree.sym * Tree.typ option * int

type align = Ael1 | Ael2 | Asu2 | Aarg0 | Aarg1 | Aarg2 | Aaut3

val round : int -> int -> int

(* i rounded up for t, as op says *)
val align : int -> Tree.typ -> align -> int

val maxround : int -> int -> int

(* a declaration's words, in the order C allows them anywhere *)
type word =
  | Char | Short | Int | Long | Signed | Unsigned | Float | Double | Void
  | Auto | Static | Extern | Typedef | Typestr | Register | Const | Volatile

val type_words : word list

(* the qualifiers the words say, as Tree's garb *)
val simpleg : word list -> int

(* the class *)
val simplec : word list -> Tree.cls

(* the type: int by default, long long a vlong *)
val simplet : word list -> Tree.typ

(* t qualified by the words *)
val garbt : Tree.typ -> word list -> Tree.typ

val mkstatic : Tree.sym -> Tree.sym

(* the declarator n, declared by f with the class and type of the words before it *)
val dodecl :
  (Tree.cls -> Tree.typ -> Tree.sym option -> unit) option ->
  Tree.cls ->
  Tree.typ -> Tree.node option -> Tree.node option

val adecl : Tree.cls -> Tree.typ -> Tree.sym option -> unit

val pdecl : Tree.cls -> Tree.typ -> Tree.sym option -> unit

val xdecl : Tree.cls -> Tree.typ -> Tree.sym option -> unit

val edecl : Tree.cls -> Tree.typ -> Tree.sym option -> unit

val sualign : Tree.typ -> unit

val tcopy : Tree.typ option -> Tree.typ option

val dotag : Tree.sym -> Tree.etype -> int -> Tree.typ

val doenum : Tree.sym -> Tree.node option -> unit

(* a block's start *)
val markdcl : unit -> unit

(* a block's end: what it hid restored *)
val revertdcl : unit -> Tree.node option

val argmark : Tree.node -> declared:bool -> unit

val dcllabel : Tree.sym -> bool -> Tree.node

val doinit :
  Tree.sym ->
  Tree.typ option -> int -> Tree.node -> Tree.node option

val contig :
  Tree.sym -> Tree.node option -> int -> Tree.node option
