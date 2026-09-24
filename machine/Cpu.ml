(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Cpu.mli *)

type stats = { mutable instructions : int }

let cache_bits = 16

(* no store invalidates an entry: the corpus has no self-modifying
 * code (plan_arm.md, decision 5) *)
let run32 ?trace (st : Arm32.state) ~pc ~svc ~signal stats =
  let size = 1 lsl cache_bits in
  let tags = Array.make size (-1) and code = Array.make size (Arm32.Undefined 0) in
  let pc = ref pc in
  while true do
    if !Linux.signal_waiting then begin
      st.next <- !pc;
      signal st !pc;
      pc := st.next
    end;
    let a = !pc in
    let slot = (a lsr 2) land (size - 1) in
    let i =
      if tags.(slot) = a then code.(slot)
      else begin
        let i = Arm32.decode (Memory.load32 st.mem a) in
        tags.(slot) <- a; code.(slot) <- i; i
      end in
    (match trace with Some f -> f a i | None -> ());
    Arm32.execute st ~addr:a ~svc i;
    stats.instructions <- stats.instructions + 1;
    pc := st.next
  done
