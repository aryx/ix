(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Proc.mli *)

open Types

let nproc = 64
let scheduler_slot = nproc
let procs : proc option array = Array.make nproc None
let nextpid = ref 1

let myproc () = match procs.(Machine.current ()) with Some p -> p | None -> failwith "myproc: the scheduler"

let all () = List.fold_right (fun o acc -> match o with Some p -> p :: acc | None -> acc) (Array.to_list procs) []

let free_slot () =
  let rec go i = if i = nproc then None else match procs.(i) with None -> Some i | Some _ -> go (i + 1) in
  go 0

let sched () = Machine.swtch scheduler_slot

let sleep ch =
  let p = myproc () in
  p.state <- Sleeping ch;
  sched ()

let wakeup ch =
  List.iter (fun p -> match p.state with Sleeping c when c = ch -> p.state <- Runnable | _ -> ()) (all ())

let yield () =
  let p = myproc () in
  p.state <- Runnable;
  sched ()

let idle = ref (fun () -> ())

let scheduler () =
  let rec loop () =
    let ran = ref false in
    for i = 0 to nproc - 1 do
      match procs.(i) with
      | Some p when p.state = Runnable ->
          ran := true;
          p.state <- Running;
          Machine.mmu_switch p.pgdir;
          Machine.swtch p.slot;
          Machine.mmu_switch 0
      | _ -> ()
    done;
    if not !ran then !idle ();
    loop () in
  loop ()
