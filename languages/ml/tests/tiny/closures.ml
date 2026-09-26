(* closures: free variables, partial application, currying through an
 * unknown function, over-application, functions returning functions *)
let add x y = x + y
let add3 x y z = x * 100 + y * 10 + z
let apply f x = f x
let apply2 f x y = f x y
let compose f g x = f (g x)
let twice f = compose f f
let make_counter () = let n = ref 0 in fun () -> incr n; !n
let () =
  let inc = add 1 in
  print_int (inc 41); print_newline ();
  print_int (apply (add 2) 40); print_newline ();
  print_int (apply2 add3 1 2 3); print_newline ();
  let f = add3 4 in let g = f 5 in print_int (g 6); print_newline ();
  print_int (apply2 (add3 7) 8 9); print_newline ();
  print_int (twice (fun x -> x * 3) 5); print_newline ();
  let c = make_counter () in let d = make_counter () in
  ignore (c ()); ignore (c ()); print_int (c ()); print_int (d ()); print_newline ();
  let k = 10 in
  let rec loop i acc = if i = 0 then acc else loop (i - 1) (acc + k) in
  print_int (loop 5 0); print_newline ();
  let fs = List.map (fun x -> fun y -> x * y) [ 1; 2; 3 ] in
  List.iter (fun f -> print_int (f 10); print_char ' ') fs; print_newline ();
  let rec even n = n = 0 || odd (n - 1) and odd n = n <> 0 && even (n - 1) in
  print_string (if even 10 && odd 7 then "ok" else "ko"); print_newline ();
  let base = 1000 in
  let rec ev n = if n = 0 then base else od (n - 1) and od n = if n = 0 then - base else ev (n - 1) in
  print_int (ev 5); print_int (od 5); print_newline ();
  let plus = ( + ) in print_int (plus 20 22); print_newline ();
  print_int (List.fold_left ( + ) 0 [ 1; 2; 3; 4 ]); print_newline ();
  let sub = ( - ) 50 in print_int (sub 8); print_newline ()
