(* variants and pattern matching: constant and non-constant
 * constructors, nested patterns, guards, as, or-patterns, constants *)
type color = Red | Green | Blue
type 'a tree = Leaf | Node of 'a tree * 'a * 'a tree
type expr = Num of int | Add of expr * expr | Mul of expr * expr | Neg of expr
let name = function Red -> "red" | Green -> "green" | Blue -> "blue"
let rec insert x = function
  | Leaf -> Node (Leaf, x, Leaf)
  | Node (l, y, r) as t -> if x < y then Node (insert x l, y, r) else if x > y then Node (l, y, insert x r) else t
let rec inorder = function Leaf -> [] | Node (l, x, r) -> inorder l @ (x :: inorder r)
let rec eval = function
  | Num n -> n
  | Add (a, b) -> eval a + eval b
  | Mul (Num 0, _) | Mul (_, Num 0) -> 0
  | Mul (a, b) -> eval a * eval b
  | Neg e -> - (eval e)
let classify n = match n with
  | 0 -> "zero" | 1 | 2 | 3 -> "small" | n when n < 0 -> "negative" | _ -> "big"
let rec describe = function
  | [] -> "empty" | [ _ ] -> "one" | [ x; y ] when x = y -> "a pair of equals" | _ :: _ :: _ -> "many"
let opt = function None -> 0 | Some x -> x
let () =
  List.iter (fun c -> print_string (name c); print_char ' ') [ Red; Green; Blue ]; print_newline ();
  let t = List.fold_left (fun t x -> insert x t) Leaf [ 5; 3; 8; 1; 4; 7; 9; 3 ] in
  List.iter (fun x -> print_int x; print_char ' ') (inorder t); print_newline ();
  print_int (eval (Add (Num 3, Mul (Num 4, Neg (Num 5))))); print_newline ();
  print_int (eval (Mul (Num 0, Num 99))); print_newline ();
  List.iter (fun n -> print_string (classify n); print_char ' ') [ 0; 2; -5; 100 ]; print_newline ();
  List.iter (fun l -> print_string (describe l); print_char ' ') [ []; [ 1 ]; [ 2; 2 ]; [ 1; 2 ]; [ 1; 2; 3 ] ]; print_newline ();
  print_int (opt (Some 5) + opt None); print_newline ();
  (match 'x' with 'a' -> print_string "a" | 'x' -> print_string "x" | _ -> print_string "other"); print_newline ()
