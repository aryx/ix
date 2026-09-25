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
let scheduler_slot = nproc                  (* the scheduler's context, the boot stack *)
let procs : proc option array = Array.make nproc None
let nextpid = ref 1

(* the clock (xv6's ticks): 100 a second *)
let ticks = ref 0

let myproc () = match procs.(Machine.current ()) with Some p -> p | None -> failwith "myproc: the scheduler"

let all () = List.fold_right (fun o acc -> match o with Some p -> p :: acc | None -> acc) (Array.to_list procs) []

let find pid = List.find_all (fun p -> p.pid = pid) (all ())

(* channels are equal when they name the same thing: a pipe, the
 * physical one *)
let same_chan a b =
  match a, b with
  | Ticks, Ticks -> true
  | Child_of x, Child_of y -> x = y
  | Pipe_readable p, Pipe_readable q -> p == q
  | Pipe_writable p, Pipe_writable q -> p == q
  | Console_input, Console_input -> true
  | _ -> false

(* back to the scheduler, from inside a system call or an interrupt *)
let sched () = Machine.swtch scheduler_slot

let sleep chan =
  let p = myproc () in
  p.state <- Sleeping chan;
  sched ()

let wakeup chan =
  List.iter (fun p -> match p.state with Sleeping c when same_chan c chan -> p.state <- Runnable | _ -> ()) (all ())

let yield () =
  let p = myproc () in
  p.state <- Runnable;
  sched ()

(* xv6's kill: marked, woken if asleep; it dies on its way back to user
 * mode (a zombie too: marked, and still reaped) *)
let kill pid =
  match find pid with
  | p :: _ ->
      p.killed <- true;
      (match p.state with Sleeping _ -> p.state <- Runnable | _ -> ());
      0
  | _ -> -1

(* a free slot, or None *)
let free_slot () =
  let rec go i = if i = nproc then None else match procs.(i) with None -> Some i | Some _ -> go (i + 1) in
  go 0

(* what the scheduler does when nothing can run: set by Main (wait for
 * an interrupt, handle it) *)
let idle = ref (fun () -> ())

(* round robin over the slots (xv6's scheduler), each process's table in
 * TTBR0 while it runs *)
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
