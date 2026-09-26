(* Declarations, as the parser meets them (dcl.c): a declarator's type
 * built from the words before it, a symbol's class and offset (a frame's
 * autos and parameters, a structure's fields), initializers made into
 * data or assignments, and C's scopes.
 *
 * The scopes: a symbol holds its current meaning, and a block's
 * declarations push what they hide on a stack of undos, a variant: its
 * mark, a name, a tag; the end of the block ([revertdcl]) pops back to
 * its mark, restoring each. 5c's is a list of Decl records with a kind
 * field.
 *
 * The initializers: [doinit] takes Tree's [init] from a cursor, where a
 * string spread over an array's elements and an expression typed already
 * (a structure's, by isstruct) are items of their own; 5c marks them in
 * the tree, as OUSED and ODOTDOT nodes.
 *
 * References: Ken Thompson, "Plan 9 C Compilers", section "Parsing":
 * "Declarations are interpreted immediately, building a block
 * structured symbol table"; H. G. Baker, "Shallow binding in Lisp 1.5"
 * (CACM 21(7), 1978): the same trick at run time, a value cell holding
 * the current binding and a stack of the shadowed ones -- here the
 * symbol's fields and the undos. *)

(* a function's name and its body, parsed: to the code generator *)
val on_function : (Tree.sym -> Tree.stmt -> unit) ref

(* the back end's, set by Gen: an initializer's data (swt.c's gextern) *)
val gextern : (Tree.sym -> Tree.expr -> int -> int -> unit) ref

(* the state the parser shares (cc.h's globals): the frame's size, the
 * block, the last declarator's type, the words' type and class, a
 * structure's elements (the last first), the function and its first
 * parameter, an enum's types *)
val stkoff : int ref
val autobn : int ref
val lastdcl : Tree.typ option ref
val lasttype : Tree.typ option ref
val lastclass : Tree.cls ref
val lastfield : int ref
val elems : Tree.typ list ref
val taggen : int ref
val firstarg : Tree.sym option ref
val firstargtype : Tree.typ option ref
val thisfn : Tree.typ option ref
val en_tenum : Tree.typ option ref
val en_cenum : Tree.typ option ref

(* an element's start and end, a structure's end, the frame's first
 * parameter (a structure's result's address), a parameter's start and
 * end, an auto *)
type align = Ael1 | Ael2 | Asu2 | Aarg0 | Aarg1 | Aarg2 | Aaut3

(* i rounded up for t, as op says *)
val align : int -> Tree.typ -> align -> int
val round : int -> int -> int
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

(* a local static's own symbol, a global's *)
val mkstatic : Tree.sym -> Tree.sym

(* the name of d declared, its type around it: t of class c, given to f
 * (xdecl, adecl, pdecl, edecl; or none); the symbol declared *)
val dodecl :
  (Tree.cls -> Tree.typ -> Tree.sym option -> unit) option -> Tree.cls -> Tree.typ -> Tree.decl -> Tree.sym option

(* an auto's, a parameter's, an external's, a structure element's *)
val adecl : Tree.cls -> Tree.typ -> Tree.sym option -> unit
val pdecl : Tree.cls -> Tree.typ -> Tree.sym option -> unit
val xdecl : Tree.cls -> Tree.typ -> Tree.sym option -> unit
val edecl : Tree.cls -> Tree.typ -> Tree.sym option -> unit

(* the elements, linked by down: a structure's body *)
val chain : Tree.typ list -> Tree.typ option

(* the offsets of a structure's elements, its width *)
val sualign : Tree.typ -> unit

(* a typedef's type for a variable: its incomplete arrays its own *)
val tcopy : Tree.typ option -> Tree.typ option

(* a tag's type, in block bn (0: the one in scope) *)
val dotag : Tree.sym -> Tree.etype -> int -> Tree.typ

(* an enumerator, of the value given or the next *)
val doenum : Tree.sym -> Tree.expr option -> unit

(* a block's start; its end: what it hid restored, its volatiles to be
 * USED *)
val markdcl : unit -> unit
val revertdcl : unit -> Tree.expr list

(* the parameters' offsets; ~declared, after their old-style
 * declarations *)
val argmark : Tree.decl -> declared:bool -> unit

(* a label, defined (true) or used, forgotten at the function's end *)
val dcllabel : Tree.sym -> bool -> Tree.label

(* the initializer of s, of type t at offset o: an auto's assignments,
 * or a static's data (by gextern) *)
val doinit : Tree.sym -> Tree.typ option -> int -> Tree.init -> Tree.expr list

(* an auto's initialization, whose array was v bytes before it: zeroed
 * first when partial (dcl.c's contig) *)
val contig : Tree.sym -> Tree.expr list -> int -> Tree.stmt list
