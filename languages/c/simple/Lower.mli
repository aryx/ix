(* A function's typed tree to a stack machine's code (simple/, the back
 * end whose contract is the behavior: plan_cc.md, decision 8).
 *
 * The machine's values are integers of 1, 2, 4 or 8 bytes, signed or
 * not, and floats of 4 or 8 ([ty]); a structure's value, a union's
 * (and on arm a vlong's, a structure to 5c) is its address, and a
 * copy moves its bytes. Every operation takes its operands from the
 * top of the stack and pushes its result, the first operand the
 * deeper. The front end's trees are used as they are: no
 * addressability, no 5c's rewrites (acom): an expression is its
 * operands, then its operator; of a binary operator's operands the one
 * that needs more of the stack goes first (Ershov's number, then a
 * Swap), unless one calls, and a call's value is computed before the
 * address it is stored to (nothing is live across x = setjmp(b)). A condition is jumps (&&, ||, !,
 * ?:), a relation's value 1 or 0.
 *
 * Calls: the arguments that call are computed first, into temporaries,
 * so that the others are stored straight into the outgoing area (at
 * their offsets, Declare's Aarg1 and Aarg2, as 7c's), the first one
 * also in R0 when it is a word; a structure's result goes to a
 * temporary whose address is the hidden first argument. This is 5c's
 * and 7c's convention, so that what simple compiles calls libc, and is
 * called by it.
 *
 * The frame: Declare's autos, then the temporaries (the arguments'
 * values, the results' structures, a switch's value), freed after each
 * statement; Gen adds the stack's spills and the outgoing area. *)

type ty = I of int * bool | F of int      (* bytes, signed; bytes *)

type target = Direct of Ix_asm.Asm.mem | Indirect

type ir =
  | Int of int64 * ty                 (* a constant *)
  | Flt of float * ty
  | Lea of Ix_asm.Asm.mem             (* a global's, an auto's, a parameter's address *)
  | Load of ty                        (* the address on top by its value *)
  | Store of ty                       (* address value: the value stored, and left *)
  | Copy of int                       (* dst src: n bytes copied, dst left *)
  | Op of Tree.binop * ty             (* a b: a op b, of the operands' type; a relation 1 or 0 *)
  | Neg of ty                         (* arm64's; 5c's front end makes them 0-x and -1^x *)
  | Com of ty
  | Cvt of ty * ty                    (* the top from a type to another *)
  | Dup | Drop | Swap | Over          (* a: a a; a: ; a b: b a; a b: a b a *)
  | Arg of int * ty                   (* the top stored at the outgoing offset *)
  | ArgBlock of int * int             (* the block on top copied there, n bytes *)
  | Call of target * ty option * ty option
                                      (* the name, or the address on top; the first
                                         argument's type if in R0; the result's *)
  | Label of int | Jmp of int
  | Jz of int | Jnz of int            (* an integer popped *)
  | Ret of ty option                  (* the value on top, returned *)

(* locals: the autos' and the temporaries' bytes; args: the outgoing
 * area's; r0: where the function stores R0 at its entry *)
type func = {
  name : Tree.sym;
  locals : int;
  args : int;
  r0 : (Ix_asm.Asm.mem * ty) option;
  code : ir list;
}

val func : Tree.sym -> Tree.stmt -> func

(* the front end's hook (Check.xcom): on arm, a vlong's operations as
 * calls to libc (Com64), bottom up; on arm64 the tree as it is *)
val calls64 : Tree.expr -> Tree.expr
