(* the collector: much allocated, some kept, across calls and closures *)
type tree = Leaf | Node of tree * int * tree
let rec make d = if d = 0 then Leaf else Node (make (d - 1), d, make (d - 1))
let rec check = function Leaf -> 0 | Node (l, x, r) -> x + check l + check r
let rec range a b = if a > b then [] else a :: range (a + 1) b
let () =
  let long = make 12 in
  let total = ref 0 in
  for i = 1 to 50 do total := !total + check (make 8) done;
  print_int !total; print_newline ();
  print_int (check long); print_newline ();
  let l = range 1 100000 in
  print_int (List.fold_left ( + ) 0 (List.map (fun x -> x mod 7) l)); print_newline ();
  let strs = List.map string_of_int (range 1 2000) in
  print_int (String.length (List.fold_left ( ^ ) "" strs)); print_newline ();
  let adders = List.map (fun x -> fun y -> x + y) (range 1 1000) in
  print_int (List.fold_left (fun acc f -> f acc) 0 adders); print_newline ();
  print_int (List.length (List.rev (range 1 200000))); print_newline ()
