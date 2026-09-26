(* lists: recursion, the prelude's List functions, append, polymorphism *)
let rec print_list = function [] -> print_newline () | x :: l -> print_int x; print_char ' '; print_list l
let rec range a b = if a > b then [] else a :: range (a + 1) b
let rec sum = function [] -> 0 | x :: l -> x + sum l
let l = range 1 10
let () =
  print_list l;
  print_int (sum l); print_newline ();
  print_list (List.rev l);
  print_list (List.map (fun x -> x * x) l);
  print_list (l @ [ 100; 200 ]);
  print_int (List.length (range 1 1000)); print_newline ();
  print_int (List.fold_left (fun a b -> a * 10 + b) 0 [ 1; 2; 3 ]); print_newline ();
  print_int (List.fold_right (fun a b -> a - b) [ 10; 3; 2 ] 0); print_newline ();
  print_list (List.filter (fun x -> x mod 3 = 0) l);
  print_string (if List.mem 7 l then "yes" else "no"); print_newline ();
  print_string (List.assoc 2 [ 1, "one"; 2, "two"; 3, "three" ]); print_newline ();
  print_string (if List.exists (fun x -> x > 9) l && List.for_all (fun x -> x > 0) l then "ok" else "ko"); print_newline ();
  List.iter (fun s -> print_string s) [ "a"; "b"; "c" ]; print_newline ();
  print_int (List.nth l 4); print_int (List.hd l); print_list (List.tl l);
  print_list (List.concat [ [ 1 ]; [ 2; 3 ]; []; [ 4 ] ]);
  let pairs = List.map (fun x -> (x, string_of_int x)) [ 1; 2 ] in
  List.iter (fun (n, s) -> print_int n; print_string s) pairs; print_newline ()
