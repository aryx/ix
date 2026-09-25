(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* mini-xv6, step 1 (plan_kernel.md): OCaml running bare-metal on the
 * Pi1, its output on the PL011. What it checks of the runtime: the
 * channels (buffered, flushed at exit), the allocation of the minor
 * heap and the major one (a list long enough to be promoted), a
 * collection, exceptions, Printf. *)

(* the list built by a loop: ocaml-light's List.init is not tail
 * recursive, and 100,000 frames overflow the 64KB stack (start.s's; no
 * guard page yet: the overflow ran down through the bss and below 0
 * before a data abort stopped it) *)
let rec upto i acc = if i < 0 then acc else upto (i - 1) (i :: acc)

let () =
  print_string "mini-xv6: OCaml on the Pi1\n";
  let l = upto 99999 [] in
  Gc.full_major ();
  Printf.printf "a list of %d, its sum %d\n" (List.length l) (List.fold_left ( + ) 0 l);
  (try print_string (List.assoc 7 [ (1, "one") ]) with Not_found -> print_string "Not_found caught\n");
  print_string "halting\n"
