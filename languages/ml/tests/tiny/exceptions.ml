(* exceptions: raised and caught, with arguments, re-raised through
 * frames, from deep recursion, in loops, nested handlers *)
exception Found of int
exception Oops of string * int
let find p l = try List.iter (fun x -> if p x then raise (Found x)) l; None with Found x -> Some x
let rec deep n = if n = 0 then raise (Oops ("bottom", 7)) else 1 + deep (n - 1)
let safe_div a b = try if b = 0 then raise Exit else a / b with Exit -> -1
let () =
  (match find (fun x -> x > 3) [ 1; 2; 5; 7 ] with Some x -> print_int x | None -> print_string "none"); print_newline ();
  (match find (fun x -> x > 30) [ 1; 2; 5; 7 ] with Some x -> print_int x | None -> print_string "none"); print_newline ();
  (try print_int (deep 10000) with Oops (s, n) -> print_string s; print_int n); print_newline ();
  print_int (safe_div 10 2 + safe_div 1 0); print_newline ();
  (try failwith "bad" with Failure s -> print_string ("failure: " ^ s)); print_newline ();
  (try ignore (List.assoc 9 [ 1, 2 ]) with Not_found -> print_string "not found"); print_newline ();
  (try (try raise Not_found with Failure _ -> print_string "wrong") with Not_found -> print_string "outer"); print_newline ();
  (try (try raise (Failure "x") with Failure s -> raise (Oops (s ^ "y", 1))) with Oops (s, _) -> print_string s); print_newline ();
  let n = ref 0 in
  for i = 1 to 1000 do try if i mod 7 = 0 then raise Exit else incr n with Exit -> () done;
  print_int !n; print_newline ();
  let r = 1 + (try 2 + raise Exit with Exit -> 10) + 100 in
  print_int r; print_newline ();
  (try invalid_arg "arg" with Invalid_argument s -> print_string s); print_newline ();
  (try ignore (String.sub "abc" 2 5) with Invalid_argument s -> print_string s); print_newline ()
