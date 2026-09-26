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

(* the pids 9pi's kernel processes take (kgenrandom and alarm at the
 * boot, kpager at the swap's start, rxmitproc at #I's attach): spent
 * at the same moments, so that the processes' pids are 9pi's (mini-9pi
 * has no such processes) *)
let kproc (_ : string) = incr nextpid

(* the clock: 100 a second *)
let ticks = ref 0

let myproc () = match procs.(Machine.current ()) with Some p -> p | None -> failwith "myproc: the scheduler"

let all () = List.fold_right (fun o acc -> match o with Some p -> p :: acc | None -> acc) (Array.to_list procs) []

let free_slot () =
  let rec go i = if i = nproc then None else match procs.(i) with None -> Some i | Some _ -> go (i + 1) in
  go 0

(* the processes ready to run, in the order they became so (Plan 9's
 * run queue, one priority): a new process after its parent's readying,
 * so run before the parent goes on (sysrfork's sched) *)
let runq = ref []

(* the process last readied by another (cpu->readied): run next when
 * the running one gives up the CPU (cooperative scheduling: a server
 * woken by a request answers at once, its client right after) *)
let readied = ref None

(* not when the CPU was idle (the scheduler's: an interrupt woke p): then
 * p gets a fresh 100ms (9pi's keeps the stale one of the process's last
 * dispatch, so an interactive command could be preempted at its first
 * tick; a divergence of mini-9pi's, for fewer races in a session) *)
let ready p =
  let cur = Machine.current () in
  if cur <> p.slot && cur <> scheduler_slot then readied := Some p;
  p.state <- Runnable;
  runq := !runq @ [ p ]

let sched () = Machine.swtch scheduler_slot

(* a pending note interrupts a sleep (Eintr), before or after *)
let eintr = "interrupted"

let interrupted p = if p.notepending then begin p.notepending <- false; raise (Error eintr) end

let sleep ch =
  let p = myproc () in
  interrupted p;
  p.state <- Sleeping ch;
  sched ();
  interrupted p

let tsleep ms =
  let until = !ticks + ((ms + 9) / 10) in
  while !ticks < until do sleep Ticks done

let wakeup ch =
  List.iter (fun p -> match p.state with Sleeping c when c = ch -> ready p | _ -> ()) (all ())

let yield () =
  ready (myproc ());
  sched ()

(* a tick's preemption: no cooperative handing over (hzsched) *)
let preempt () = readied := None; yield ()

let idle = ref (fun () -> ())

(* the running process's slice: 100ms from its dispatch (hzsched:
 * "unless preempted, get to run for at least 100ms") *)
let schedticks = ref 0

let preempt_due () = !ticks > !schedticks && !runq <> []

(* the run queue's first, its table in TTBR0 while it runs; a dead one's
 * slot freed once it is off its kernel stack *)
let scheduler () =
  let rec loop () =
    (* the readied process first (its slice going on), or the queue's *)
    let next =
      match !readied with
      | Some p when p.state = Runnable && List.memq p !runq ->
          runq := List.filter (fun q -> q != p) !runq; Some (p, false)
      | _ -> (match !runq with [] -> None | p :: rest -> runq := rest; Some (p, true)) in
    readied := None;
    (match next with
     | None -> !idle ()
     | Some (p, fresh) ->
         if p.state = Runnable then begin
           p.state <- Running;
           if fresh then schedticks := !ticks + 10;
           Machine.mmu_switch p.pgdir;
           Machine.swtch p.slot;
           Machine.mmu_switch 0;
           if p.state = Zombie then begin
             Machine.proc_free p.slot;
             procs.(p.slot) <- None
           end
         end);
    loop () in
  loop ()

(*****************************************************************************)
(* Notes *)
(*****************************************************************************)

let nnote = 5

let postnote p msg flag =
  (* a note that ends a process with no handler for it: the only one *)
  if flag <> Nuser && (p.notify = 0 || p.notified) then p.notes <- [];
  let ok = List.length p.notes < nnote in
  if ok then p.notes <- p.notes @ [ msg, flag ];
  p.notepending <- true;
  (match p.state with
   | Sleeping (Rendez _) ->
       p.rgrp.rend <- List.filter (fun q -> q != p) p.rgrp.rend;
       p.rendval <- -1;
       ready p
   | Sleeping _ -> ready p
   | _ -> ());
  ok

let find pid = try Some (List.find (fun p -> p.pid = pid && p.state <> Zombie) (all ())) with Not_found -> None

