(* The compiler's data: C's types, the tree of an expression or a
 * statement, the symbols, and what the front end asks of a machine
 * (cc.h's Type, Node, Sym; sub.c's tables).
 *
 * A type's kind is a variant, [etype]; the tables that say which kinds
 * an operator takes ([tasign], [tadd]...) are functions from the left
 * kind to a bit set of the right ones. 5c's layout is kept where it is
 * the output's: the listing prints the same numbers, and a declaration's
 * words are parsed as a set of bits (Declare's [typebitor]). The
 * records are mutable, as 5c's: the passes rewrite the tree in place.
 *
 * One file is compiled per run, and the state is global: [lineno], the
 * symbol table [hash], the machine [mach].
 *
 * References: Ken Thompson, "Plan 9 C Compilers" (in principia's
 * compilers/docs/compiler.ms; first in Proc. Summer 1990 UKUUG
 * Conference), its section "Implementation": "four machine-independent
 * passes, four machine-dependent passes, and an output pass", which this
 * tree carries from one to the next; D. E. Knuth, The Art of Computer
 * Programming, vol. 3, section 6.4, for [lookup]'s table, chained
 * buckets with a cheap hash. *)

(* a type's kind; Tdot is a prototype's ..., Told an old-style one's
 * parameters *)
type etype =
  | Txxx | Tchar | Tuchar | Tshort | Tushort | Tint | Tuint | Tlong | Tulong | Tvlong | Tuvlong | Tfloat | Tdouble
  | Tind | Tfunc | Tarray | Tvoid | Tstruct | Tunion | Tenum | Tdot | Told

(* the sets of kinds, named by their members' initials as sub.c's:
 * typechlp is char, short, long (of each sign) and pointer *)
val typei : etype -> bool
val typeu : etype -> bool
val typesuv : etype -> bool
val typeilp : etype -> bool
val typechl : etype -> bool
val typechlv : etype -> bool
val typechlvp : etype -> bool
val typechlp : etype -> bool
val typev : etype -> bool
val typefd : etype -> bool
val typeaf : etype -> bool
val typesu : etype -> bool

(* whether an operator takes a left and a right operand of these kinds
 * (sub.c's tables) *)
val tasign : etype -> etype -> bool
val tasadd : etype -> etype -> bool
val tcast : etype -> etype -> bool
val tadd : etype -> etype -> bool
val tsub : etype -> etype -> bool
val tmul : etype -> etype -> bool
val tand : etype -> etype -> bool
val trel : etype -> etype -> bool
val tfunct : 'a -> etype -> bool
val tindir : 'a -> etype -> bool
val tdots : 'a -> etype -> bool
val tnot : 'a -> etype -> bool
val targ : 'a -> etype -> bool

(* the type of l op r (sub.c's tab: double op float is float) *)
val arith_tab : etype -> etype -> etype

(* the integral promotion: Plan 9's, unsigned preserving *)
val promote : etype -> etype

(* storage classes, and qualifiers (GCONSTNT...) *)
type cls = Cxxx | Cauto | Cextern | Cglobl | Cstatic | Clocal | Ctypedef | Ctypestr | Cparam | Cselem | Clabel | Cexreg

val cname : cls -> string

(* a type's qualifiers, as bits *)
val gconstnt : int
val gvolatile : int

type op =
  | OXXX | OADD | OADDR | OAND | OANDAND | OARRAY | OAS | OASI | OASADD | OASAND | OASASHL | OASASHR | OASDIV
  | OASHL | OASHR | OASLDIV | OASLMOD | OASLMUL | OASLSHR | OASMOD | OASMUL | OASOR | OASSUB | OASXOR | OBIT
  | OBREAK | OCASE | OCAST | OCOMMA | OCOND | OCONST | OCONTINUE | ODIV | ODOT | ODOTDOT | ODWHILE | OENUM
  | OEQ | OFOR | OFUNC | OGE | OGOTO | OGT | OHI | OHS | OIF | OIND | OINDREG | OINIT | OLABEL | OLDIV | OLE
  | OLIST | OLMOD | OLMUL | OLO | OLS | OLSHR | OLT | OMOD | OMUL | ONAME | ONE | ONOT | OOR | OOROR
  | OPOSTDEC | OPOSTINC | OPREDEC | OPREINC | OPROTO | OREGISTER | ORETURN | OSET | OSIGN | OSIZE | OSTRING
  | OLSTRING | OSTRUCT | OSUB | OSWITCH | OUNION | OUSED | OWHILE | OXOR | ONEG | OCOM | OPOS | OELEM
  | OTST | OINDEX | OFAS | OREGPAIR | OEXREG

val opname : op -> string

type sym = {
  name : string;
  mutable typ : typ option;
  mutable suetag : typ option;
  mutable tenum : typ option;
  mutable macro : string option;     (* its first char is its number of arguments + 1, as mac.c *)
  mutable soffset : int;
  mutable svconst : int64;
  mutable sfconst : float;
  mutable label : node option;
  mutable lexical : int;              (* the token: a name or a keyword *)
  mutable block : int;
  mutable sueblock : int;
  mutable sclass : cls;
  mutable aused : bool;
}

and typ = {
  mutable tsym : sym option;          (* a structure element's name *)
  mutable tag : sym option;
  mutable link : typ option;
  mutable down : typ option;
  mutable width : int;
  mutable offset : int;
  mutable etype : etype;
  mutable garb : int;
}

(* how a node can be an instruction's operand as it is; the others
 * are computed into a register (sgen.c's addable numbers) *)
and addr =
  | Anone
  | Alvalue                           (* the typechecker's: an l-value *)
  | Aaddr_name | Aaddr_reg            (* $name, $offset(reg) *)
  | Aname | Areg | Aindreg | Aconst   (* name, stack slot; reg; offset(reg); $c *)

and node = {
  mutable left : node option;
  mutable right : node option;
  mutable pc : int;
  mutable reg : int;
  mutable xoffset : int;
  mutable fconst : float;
  mutable vconst : int64;
  mutable cstring : string;
  mutable nsym : sym option;
  mutable ntype : typ option;
  mutable lineno : int;
  mutable op : op;
  mutable nclass : cls;
  mutable complex : int;
  mutable addable : addr;
  mutable ngarb : int;
}

(* the machine, as the front end sees it: widths and alignment
 * (goken's ewidth, align, maxround in each back end's swt.c and gc.h) *)
type machine = {
  thechar : char;
  sz_ind : int;
  maxalign : int;                     (* SZ_LONG on arm, SZ_VLONG on arm64 *)
  typecmplx : etype -> bool;             (* returned through a pointer *)
  typeword : etype -> bool;              (* passed in a register *)
  typeswitch : etype -> bool;
  machcap : node option -> bool;      (* what the back end does itself *)
}

val mach : machine option ref

val m : unit -> machine

val ewidth : etype -> int

(* a constant truncated and extended as a value of the type *)
(* a conversion that makes no code (txt.c's ncast) *)
val ncast : etype -> etype -> bool

val convvtox : int64 -> etype -> int64

val lineno : int ref

val nearln : int ref

(* a node, at the current line *)
val node : op -> node option -> node option -> node

(* a node, at the line being diagnosed *)
val node1 : op -> node option -> node option -> node

(* a name of s, of type t and class c, at off *)
val name_of : sym -> typ option -> cls -> int -> node

(* s as it is declared now *)
val name_node : sym -> node

(* a constant of type t *)
val const_node : typ -> int64 -> node

val copy_into : node -> node -> unit

val dup : node -> node

val typ : etype -> typ option -> typ

val copytyp : typ -> typ

val ty : etype -> typ

val init_types : unit -> unit

val l : node -> node

val r : node -> node

val t : node -> typ

val et : node -> etype

val link : typ -> typ

val sym : node -> sym

val nhash : int

val hash : sym list array

(* the symbol of a name, made if new *)
val lookup : string -> sym

exception Error of string

val error_at : int -> ('a, unit, string, 'b) format4 -> 'a

(* an error at n's line (or the line diagnosed): Error, which stops the run *)
val diag : node option -> ('a, unit, string, 'b) format4 -> 'a

val snap : typ -> unit

val sametype : typ option -> typ option -> bool

val show_type : typ option -> string

(* an operand as it is, needing no instruction *)
val addressable : node -> bool

val fnname : node option -> string

(* the tree, as 5c's -x prints it *)
val prtree : node option -> string -> string
