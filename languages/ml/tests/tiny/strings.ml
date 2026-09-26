(* strings and characters *)
let rec repeat s n = if n = 0 then "" else s ^ repeat s (n - 1)
let rev s =
  let n = String.length s in
  let rec go i acc = if i = n then acc else go (i + 1) (String.make 1 s.[i] ^ acc) in
  go 0 ""
let () =
  let s = "hello" ^ ", " ^ "world" in
  print_string s; print_newline ();
  print_int (String.length s); print_newline ();
  print_char s.[4]; print_char s.[7]; print_newline ();
  print_string (String.sub s 7 5); print_newline ();
  print_string (repeat "ab" 5); print_newline ();
  print_string (rev "stressed"); print_newline ();
  print_int (Char.code 'A'); print_char (Char.chr 98); print_newline ();
  print_string (string_of_int (-12345) ^ string_of_int 0 ^ string_of_int max_int); print_newline ();
  print_string (if "abc" < "abd" then "lt" else "ge"); print_string (if "abc" = "ab" ^ "c" then " eq" else " ne");
  print_string (if "b" > "abc" then " gt" else " le"); print_newline ();
  print_int (compare "x" "x"); print_int (compare "a" "b"); print_newline ();
  print_string (match "two" with "one" -> "1" | "two" -> "2" | _ -> "?"); print_newline ();
  print_endline "line"; print_string "\ttab\\ \"quoted\"\n"; print_string (String.make 3 'z'); print_newline ()
