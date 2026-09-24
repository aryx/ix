(* The compiler's data: C's types, the trees the parser makes of
 * expressions, statements, declarators and initializers, the symbols,
 * and what the front end asks of a machine (cc.h's Type, Node, Sym;
 * sub.c's tables).
 *
 * A type's kind is a variant, [etype]; the tables that say which kinds
 * an operator takes ([tasign], [tadd]...) are predicates on the left and
 * right kinds, and the usual conversions a rule ([arith_tab]).
 *
 * The trees are ADTs, where 5c's are one Node with an op, a left and a
 * right: an [expr] is its [kind] ([Binary], [Assign], [Call]...) with
 * what the passes learn of it (its type, its complexity, its
 * addressability); the passes (Check, Gen's xcom) return new trees
 * rather than rewrite them in place. Statements, declarators and
 * initializers have their own types ([stmt], [decl], [init]); in 5c they
 * are Nodes too. Symbols and types stay mutable records: declarations
 * complete them as they come.
 *
 * One file is compiled per run, and the state is global: [lineno], the
 * symbol table [hash], the machine [mach].
 *
 * References: Ken Thompson, "Plan 9 C Compilers" (in principia's
 * compilers/docs/compiler.ms; first in Proc. Summer 1990 UKUUG
 * Conference), its section "Implementation": "four machine-independent
 * passes, four machine-dependent passes, and an output pass", which these
 * trees carry from one to the next; D. E. Knuth, The Art of Computer
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
val tadd : etype -> etype -> bool
val tsub : etype -> etype -> bool
val tmul : etype -> etype -> bool
val tand : etype -> etype -> bool
val trel : etype -> etype -> bool
val tcast : etype -> etype -> bool
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

(* the operators; L and Lo, Ls, Hi, Hs are the unsigned ones *)
type binop =
  | Add | Sub | Mul | Div | Mod | Lmul | Ldiv | Lmod
  | And | Or | Xor | Ashl | Ashr | Lshr
  | Eq | Ne | Lt | Le | Gt | Ge | Lo | Ls | Hi | Hs
  | Andand | Oror | Comma

type unop = Ind | Addr | Neg | Com | Not | Pos | Cast | Preinc | Predec | Postinc | Postdec

val binop_name : binop -> string
val unop_name : unop -> string

(* Eq ... Hs *)
val is_rel : binop -> bool

type sym = {
  name : string;
  mutable typ : typ option;
  mutable suetag : typ option;
  mutable tenum : typ option;
  mutable macro : string option;     (* its first char is its number of arguments + 1, as mac.c *)
  mutable soffset : int;
  mutable svconst : int64;
  mutable sfconst : float;
  mutable label : label option;
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

(* a function's label: defined, and where *)
and label = { lsym : sym; mutable defined : bool; mutable lpc : int }

(* how an expression can be an instruction's operand as it is; the
 * others are computed into a register (sgen.c's addable) *)
type addr =
  | Anone
  | Aaddr_name | Aaddr_reg            (* $name, $offset(reg) *)
  | Aname | Areg | Aindreg | Aconst   (* name or stack slot; reg; offset(reg); $c *)

(* an expression: its kind, and what the passes learn of it *)
type expr = {
  e : kind;
  t : typ;                            (* untyped until typed *)
  line : int;
  complex : int;                      (* the registers it needs (Sethi-Ullman) *)
  addable : addr;
}

and kind =
  | Name of sym * cls * int           (* a symbol, its class, an offset *)
  | Const of int64
  | Fconst of float
  | Str of string                     (* a literal, before typing *)
  | Lstr of string                    (* L"...": its runes, 4 bytes each *)
  | Reg of int
  | Indreg of int * int               (* offset(reg) *)
  | Unary of unop * expr
  | Binary of binop * expr * expr
  | Assign of binop option * expr * expr   (* x = y, x op= y *)
  | Cond of expr * expr * expr
  | Call of expr * expr list
  | Elem of expr * sym                (* x.m, before typing *)
  | Dot of expr * int                 (* a member, at its offset, of a structure that is no l-value *)
  | Sizeof of expr
  | Sizeof_type of typ
  | Typed of expr                     (* an initializer's, typed already: not again *)

type stmt =
  | Expr of expr
  | Block of stmt list
  | If of expr * stmt * stmt option
  | While of expr * stmt
  | Dowhile of stmt * expr
  | For of stmt * expr option * stmt * stmt   (* its start, test, step and body *)
  | Switch of expr * stmt
  | Case of expr option               (* default: None *)
  | Label of label
  | Goto of label
  | Break
  | Continue
  | Return of expr option * typ       (* the function's result *)
  | Used of expr list
  | Set of expr list

(* a declarator: the type around a name *)
type decl =
  | Dnone                             (* abstract *)
  | Dname of sym
  | Dptr of int * decl                (* its qualifiers, as garb *)
  | Dfunc of decl * param list
  | Darray of decl * expr option
  | Dbit of decl * expr

and param = Pname of sym | Proto of typ * decl | Pdots

(* an initializer, whose designators are items of the list *)
type init =
  | Iexpr of expr
  | Ilist of init list
  | Iindex of expr                    (* [e] = *)
  | Ielem of sym                      (* .m = *)

(* the machine, as the front end sees it: widths and alignment
 * (goken's ewidth, align, maxround in each back end's swt.c and gc.h) *)
type machine = {
  thechar : char;
  sz_ind : int;
  maxalign : int;                     (* SZ_LONG on arm, SZ_VLONG on arm64 *)
  typecmplx : etype -> bool;          (* returned through a pointer *)
  typeword : etype -> bool;           (* passed in a register *)
  typeswitch : etype -> bool;
  machcap : expr option -> bool;      (* what the back end does itself *)
}

val mach : machine option ref
val m : unit -> machine

(* the machine's widths: a pointer's is its *)
val ewidth : etype -> int

(* a conversion that makes no code (txt.c's ncast) *)
val ncast : etype -> etype -> bool

(* a constant truncated and extended as a value of the type *)
val convvtox : int64 -> etype -> int64

(* the line being read, and the one diagnosed *)
val lineno : int ref
val nearln : int ref

val typ : etype -> typ option -> typ
val copytyp : typ -> typ

(* an expression's type before typing, or an undeclared name's *)
val untyped : typ

(* the basic types, one of each: made by init_types *)
val ty : etype -> typ
val init_types : unit -> unit

(* an expression, untyped unless t, at the line being read unless line *)
val mk : ?t:typ -> ?line:int -> kind -> expr

(* a name of s, of type t and class c, at off *)
val name_of : sym -> typ -> cls -> int -> expr

(* s as it is declared now *)
val name_node : sym -> expr

(* a constant of type t *)
val const_node : typ -> int64 -> expr

val et : expr -> etype

(* a type's link, sure to be there: a pointer's, an array's... *)
val link : typ -> typ

(* the symbol table, and a name's symbol, made if new *)
val nhash : int
val hash : sym list array
val lookup : string -> sym

(* an error, which stops the run: at a line, at an expression's (or the
 * line diagnosed) *)
exception Error of string
val error_at : int -> ('a, unit, string, 'b) format4 -> 'a
val diag : expr option -> ('a, unit, string, 'b) format4 -> 'a

(* a structure known only by its tag given its elements *)
val snap : typ -> unit

(* the same type, to dcl.c's depth; of two types there *)
val sametype : typ option -> typ option -> bool
val same : typ -> typ -> bool

val show_type : typ option -> string

(* an operand as it is, needing no instruction *)
val addressable : expr -> bool

val is_const : expr -> bool

(* the offset of a name or offset(reg) moved by d *)
val plus : expr -> int -> expr

(* List.map, left to right: the passes have effects *)
val map_lr : ('a -> 'b) -> 'a list -> 'b list

(* the -x dump of a function's tree *)
val prtree : string -> stmt -> string
