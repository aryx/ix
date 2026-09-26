(* From Scope's tree to a stack machine (plan_ml.md, decision 6: TinyC's
 * design, and tiny-ml's, whose code this generalizes): expressions push
 * their value, an operation pops its operands, statements are labels
 * and jumps. What was Lambda, Match and Closure in the plan is here,
 * each a part:
 *
 * - {b patterns} a sequence of tests, each jumping to the next clause
 *   (the tutorial's section 7): the clauses in order;
 * - {b closures}: a function is code with its closure in slot 0 and its
 *   parameters after, its free variables fields of the closure; a
 *   function without free variables is a static block; a call of a
 *   known function (a let or a toplevel of this unit) with all its
 *   arguments is a direct call, any other one argument at a time
 *   through the closure's first field (curry functions, eval/apply);
 * - {b primitives}: an external "%name" an instruction, another a call
 *   of the runtime's C.
 *
 * Nothing here knows the machine: an integer is an ML integer (Gen tags
 * it), a static block a symbol (Gen adds a word for its value), and a
 * frame's slots are numbers. Arguments are pushed from the last, as
 * OCaml evaluates them, so an operation's first operand is on top. *)

type rel = Eq | Ne | Lt | Le | Gt | Ge

type op =
  | Add | Sub | Mul | Div | Mod | And | Or | Xor | Lsl | Lsr | Asr
  | Cmp of rel          (* integers *)
  | Poly of rel         (* compare's: inlined on integers, else the runtime's *)
  | Neg | Not | IsInt | Tag | Size

type target = Direct of string | Code of int

type ir =
  | Int of int                        (* an ML integer, tagged by Gen *)
  | Block of string                   (* a static block's value: its symbol + a word *)
  | Sym of string                     (* a symbol's address: a function's code *)
  | Get of int | Set of int           (* a slot of the function's frame on the value stack *)
  | GetG of string | SetG of string   (* a global *)
  | Field of int                      (* a block by its field *)
  | SetField of int                   (* the value below the block stored in its field *)
  | Index                             (* a block, an index (ML) by the field; bounds checked *)
  | SetIndex                          (* a block, an index, a value; bounds checked *)
  | Alloc of int * int                (* a tag, n values by the block, the top its field 0 *)
  | Op of op
  | Call of target * int * bool       (* the closure then n arguments by the result; a tail call *)
  | CallC of string * int             (* the runtime's function of n arguments *)
  | Label of int | Jmp of int
  | Jz of int | Jnz of int            (* false is the ML 0 *)
  | Drop
  | Ret
  | Raise                             (* the top raised; its place taken by the result, never seen *)
  | TryEnter of int * int             (* the k-th handler of the function, its code *)
  | TryExit of int
  | Catch of int                      (* the handler's entry: the exception pushed *)

type func = { name : string; nparams : int; nslots : int; code : ir list }

(* the static data *)
type data =
  | String of string * string         (* a string block: symbol, bytes *)
  | Float of string * string          (* a float's block: symbol, the literal *)
  | Closure of string * string * string   (* symbol: [entry code; n-ary code] *)
  | Exception of string * string      (* an exception: symbol, its name's string symbol *)
  | Global of string * string option  (* a global, statically a block's value *)
  | Roots of string * string list     (* the unit's globals, for the collector *)

type unit_ = { funcs : func list; data : data list }

(* a unit (its module's name), its init function M.init and the
 * curry functions it needs (ml_curry<n>_<k>, one per unit) *)
val unit_ : string -> Scope.item list -> unit_

(* the symbols' names: an operator's characters as $ and their code *)
val mangle : string -> string

(* -dir *)
val show : ir -> string
