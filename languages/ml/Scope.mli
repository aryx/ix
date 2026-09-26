(* Names resolved (plan_ml.md, decision 3; the tutorial's section 5).
 * Modules have no functors, so a module is only a name space known at
 * compile time: Scope flattens them, nested (module R = struct ... end)
 * and aliased (module P = Machine.Phys) ones included, and replaces
 * each name by what it denotes:
 *
 * - a value by a local variable (a unique number), a global (a module's
 *   toplevel value, a symbol), or a primitive (an external);
 * - a constructor by its number among its type's constant ones or its
 *   tag among the others, and its arity; an exception by its global;
 * - a label by its field's position, the record's size, whether it is
 *   mutable: the last type declared with that label, as 1.07's.
 *
 * Another unit's names come from its .mli, read as source when the unit
 * is first named (its .ml when it has none), as a C compiler reads a
 * header: no compiled interface. Pervasives is opened first. *)

(* a type, resolved: a constructor is its declaration, which an
 * abbreviation (type t = int * int) expands to, its parameters named *)
type ty = Tvar of string | Tarrow of ty * ty | Ttuple of ty list | Tconstr of tdecl * ty list
and tdecl = { tpath : string; tparams : string list; mutable tabbrev : ty option }

type var = { vname : string; vid : int }

(* gsym, the symbol: M.x, or M.x/2 for a toplevel value a later one of
 * the same name shadows (the last is the one exported) *)
type global = { gpath : string list; gname : string; mutable gsym : string; gtype : ty option (* its .mli's *) }

type value =
  | Local of var
  | Global of global
  | Prim of string * int * ty   (* an external: its primitive, its arity (its type's arrows), its type *)

(* a constructor: its kind, its arity, and its type's numbers of
 * constant and non-constant constructors (a switch's size) *)
type kind = Const of int | Block of int | Exn of global
(* ctype: its type's parameters, its arguments' types, its result's *)
type cons = { cname : string; kind : kind; arity : int; nconst : int; nblock : int; ctype : string list * ty list * ty }

(* ltype: its type's parameters, the field's type, the record's *)
type label = { lname : string; pos : int; mut : bool; size : int; ltype : string list * ty * ty }

type pattern =
  | Pany
  | Pvar of var
  | Palias of pattern * var
  | Pconst of Ast.constant
  | Prange of char * char
  | Ptuple of pattern list
  | Pcons of cons * pattern list
  | Precord of (label * pattern) list
  | Por of pattern * pattern
  | Pconstraint of pattern * ty

type expr = { e : exp; loc : int }

and exp =
  | Evar of value
  | Econst of Ast.constant
  | Elet of bool * (pattern * expr) list * expr   (* recursive *)
  | Efunction of case list
  | Eapply of expr * expr list
  | Ematch of expr * case list
  | Etry of expr * case list
  | Etuple of expr list
  | Econs of cons * expr list
  | Erecord of int * (label * expr) list          (* the record's size *)
  | Ewith of expr * int * (label * expr) list
  | Efield of expr * label
  | Esetfield of expr * label * expr
  | Earray of expr list
  | Eif of expr * expr * expr option
  | Eseq of expr * expr
  | Ewhile of expr * expr
  | Efor of var * expr * expr * Ast.dir * expr
  | Eassert of expr
  | Econstraint of expr * ty

and case = pattern * expr option * expr

(* a unit's toplevel, in order: a let's variables then stored in their
 * globals; an exception's global made *)
type item =
  | Ieval of expr
  | Ivalue of bool * (pattern * expr) list * (var * global) list
  | Iexception of global * string
  | Iexternal of global * string * int * ty   (* a global too, for an importer whose .mli says val *)

exception Error of int * string

(* the unit's source, by module name: its interface (.mli), or its
 * implementation when it has none; None if not found *)
type loader = string -> [ `Sig of Ast.signature | `Str of Ast.structure ] option

(* a unit's implementation, M the module's name (its file's,
 * capitalized) *)
val implementation : loader -> string -> Ast.structure -> item list

(* the predefined types *)
val int_t : ty
val char_t : ty
val string_t : ty
val float_t : ty
val bool_t : ty
val unit_t : ty
val exn_t : ty
val array_d : tdecl
val list_d : tdecl
val format_d : tdecl

(* a type the current unit declares, by its path *)
val own_type : string -> tdecl option

(* a global's symbol, M.x *)
val symbol : string list -> string -> string

(* the unit's own interface, if it has one: its values' types *)
val interface : unit -> (string * ty) list option

(* the other units the last implementation named (-M) *)
val units_named : unit -> string list

(* -dscope *)
val show_item : item -> string
