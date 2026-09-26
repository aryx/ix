(* integers: tagged arithmetic, division, the bit operations, comparisons *)
let p n = print_int n; print_char ' '
let () =
  p (3 + 4); p (3 - 10); p (6 * 7); p (-6 * 7); p (-6 * -7); p (17 / 5); p (-17 / 5); p (17 mod 5); p (-17 mod 5);
  print_newline ();
  p (12 land 10); p (12 lor 3); p (12 lxor 10); p (1 lsl 10); p (1024 lsr 3); p (-1024 asr 3); p (-1 lsr 60);
  p (lnot 5); p (- (5)); p (abs (-9)); print_newline ();
  p max_int; p min_int; p (max_int + 1); p (min_int - 1); print_newline ();
  print_string (if 3 < 4 then "lt " else "ge "); print_string (if 4 <= 4 then "le " else "gt ");
  print_string (if -3 > 4 then "gt " else "le "); print_string (if 5 >= 6 then "ge " else "lt ");
  print_string (if 7 = 7 then "eq " else "ne "); print_string (if 7 <> 7 then "ne" else "eq"); print_newline ();
  p (min 3 (-2)); p (max 3 (-2)); p (succ 41); p (pred 43); p (compare 3 5); p (compare 5 3); p (compare 4 4);
  print_newline ()
