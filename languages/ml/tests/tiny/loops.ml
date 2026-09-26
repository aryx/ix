(* references, while, for, and tail calls in loops of a million *)
let rec count n acc = if n = 0 then acc else count (n - 1) (acc + 1)
let rec even n = if n = 0 then true else odd (n - 1)
and odd n = if n = 0 then false else even (n - 1)
let () =
  let r = ref 0 in
  for i = 1 to 10 do r := !r + i done;
  print_int !r; print_newline ();
  for i = 5 downto 1 do print_int i done; print_newline ();
  let i = ref 0 and s = ref 0 in
  while !i < 100 do incr i; s := !s + !i done;
  print_int !s; print_newline ();
  print_int (count 1000000 0); print_newline ();
  print_string (if even 1000001 then "even" else "odd"); print_newline ();
  (* claude: not with a ref, let g = !f in f := (fun x -> g x * k): ocaml-light's
   * ocamlopt makes g an alias of f, and prints 1 (plan_ml.md's Status) *)
  let f = List.fold_left (fun g k -> fun x -> g x * k) (fun x -> x) [ 1; 2; 3 ] in
  print_int (f 1); print_newline ();
  let rec go n = if n > 0 then (decr i; go (n - 1)) in go 50; print_int !i; print_newline ()
