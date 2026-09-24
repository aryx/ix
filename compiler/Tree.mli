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

type etype =
    Txxx
  | Tchar
  | Tuchar
  | Tshort
  | Tushort
  | Tint
  | Tuint
  | Tlong
  | Tulong
  | Tvlong
  | Tuvlong
  | Tfloat
  | Tdouble
  | Tind
  | Tfunc
  | Tarray
  | Tvoid
  | Tstruct
  | Tunion
  | Tenum
  | Tdot
  | Tauto
  | Textern
  | Tstatic
  | Ttypedef
  | Ttypestr
  | Tregister
  | Tconstnt
  | Tvolatile
  | Tunsigned
  | Tsigned
  | Tfile
  | Told

val b : etype -> int

val bclass : int

val bgarb : int

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

(* a table's value for a kind, 0 if not in it *)
val table : ('a * int) list -> 'a -> int

val tasign : etype -> int

val tasadd : etype -> int

val tcast : etype -> int

val tadd : etype -> int

val tsub : etype -> int

val tmul : etype -> int

val tand : etype -> int

val trel : etype -> int

val tfunct : 'a -> int

val tindir : 'a -> int

val tdots : 'a -> int

val tnot : 'a -> int

val targ : 'a -> int

(* the type of l op r (sub.c's tab: double op float is float) *)
val arith_tab : etype -> etype -> etype

(* the integral promotion: Plan 9's, unsigned preserving *)
val promote : etype -> etype

type cls =
    Cxxx
  | Cauto
  | Cextern
  | Cglobl
  | Cstatic
  | Clocal
  | Ctypedef
  | Ctypestr
  | Cparam
  | Cselem
  | Clabel
  | Cexreg

val cname : cls -> string

val gconstnt : int

val gvolatile : int

type op =
    OXXX
  | OADD
  | OADDR
  | OAND
  | OANDAND
  | OARRAY
  | OAS
  | OASI
  | OASADD
  | OASAND
  | OASASHL
  | OASASHR
  | OASDIV
  | OASHL
  | OASHR
  | OASLDIV
  | OASLMOD
  | OASLMUL
  | OASLSHR
  | OASMOD
  | OASMUL
  | OASOR
  | OASSUB
  | OASXOR
  | OBIT
  | OBREAK
  | OCASE
  | OCAST
  | OCOMMA
  | OCOND
  | OCONST
  | OCONTINUE
  | ODIV
  | ODOT
  | ODOTDOT
  | ODWHILE
  | OENUM
  | OEQ
  | OFOR
  | OFUNC
  | OGE
  | OGOTO
  | OGT
  | OHI
  | OHS
  | OIF
  | OIND
  | OINDREG
  | OINIT
  | OLABEL
  | OLDIV
  | OLE
  | OLIST
  | OLMOD
  | OLMUL
  | OLO
  | OLS
  | OLSHR
  | OLT
  | OMOD
  | OMUL
  | ONAME
  | ONE
  | ONOT
  | OOR
  | OOROR
  | OPOSTDEC
  | OPOSTINC
  | OPREDEC
  | OPREINC
  | OPROTO
  | OREGISTER
  | ORETURN
  | OSET
  | OSIGN
  | OSIZE
  | OSTRING
  | OLSTRING
  | OSTRUCT
  | OSUB
  | OSWITCH
  | OUNION
  | OUSED
  | OWHILE
  | OXOR
  | ONEG
  | OCOM
  | OPOS
  | OELEM
  | OTST
  | OINDEX
  | OFAS
  | OREGPAIR
  | OEXREG

val opname : op -> string

type sym = {
  name : string;
  mutable typ : typ option;
  mutable suetag : typ option;
  mutable tenum : typ option;
  mutable macro : string option;
  mutable soffset : int;
  mutable svconst : int64;
  mutable sfconst : float;
  mutable label : node option;
  mutable lexical : int;
  mutable block : int;
  mutable sueblock : int;
  mutable sclass : cls;
  mutable aused : bool;
}
and typ = {
  mutable tsym : sym option;
  mutable tag : sym option;
  mutable link : typ option;
  mutable down : typ option;
  mutable width : int;
  mutable offset : int;
  mutable etype : etype;
  mutable garb : int;
}
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
  mutable addable : int;
  mutable ngarb : int;
}

(* what the front end asks of the back end: sizes, which types are words, the no-op casts, what it computes itself *)
type machine = {
  thechar : char;
  sz_ind : int;
  maxalign : int;
  typecmplx : etype -> bool;
  typeword : etype -> bool;
  typeswitch : etype -> bool;
  ncast : etype -> int;
  machcap : node option -> bool;
}

val mach : machine option ref

val m : unit -> machine

val ewidth : etype -> int

(* a constant truncated and extended as a value of the type *)
val convvtox : int64 -> etype -> int64

val lineno : int ref

val nearln : int ref

(* a node, at the current line *)
val node : op -> node option -> node option -> node

(* a node, at the line being diagnosed *)
val node1 : op -> node option -> node option -> node

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

val fnname : node option -> string

(* the tree, as 5c's -x prints it *)
val prtree : node option -> string -> string
