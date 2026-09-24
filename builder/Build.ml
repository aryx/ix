(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Build.mli *)

type flags = {
  dry : bool;
  touch : bool;
  always : bool;
  keep_going : bool;
  explain : bool;
}

type io = {
  run : Recipe.job -> slot:int -> env:(string * string list) list -> int;
  wait : unit -> (int * Recipe.ended) option;
  stat : string -> float;
  exists : string -> bool;
  touch : string -> unit;
  delete : string -> unit;
  prog : string -> string -> string -> bool;
  now : unit -> float;
  print : string -> unit;
  eprint : string -> unit;
  cwd : string;
  pid : int;
}

type status = Notmade | Beingmade | Made

type t = {
  mk : Mkfile.t;
  g : Graph.t;
  io : io;
  flags : flags;
  ood : Outofdate.ctx;
  times : (string, float) Hashtbl.t;     (* date stamps, once changed *)
  status : (string, status) Hashtbl.t;
  queue : Recipe.job Queue.t;
  mutable slots : (int * Recipe.job) option array;
  mutable running : int;
  mutable errors : int;
  mutable busy : float array;             (* -u: time with n jobs running *)
  mutable tick : float;
}

exception Failed

let time_of (g : Graph.t) times name =
  match Hashtbl.find_opt times name with
  | Some x -> x
  | None -> (match Graph.find g name with Some n -> n.time | None -> 0.)

let create ?hashes mk g io flags =
  let times = Hashtbl.create 101 in
  { mk; g; io; flags; times;
    ood = Outofdate.create ?hashes ~time:(time_of g times) ~prog:io.prog ();
    status = Hashtbl.create 101; queue = Queue.create (); slots = [| None |];
    running = 0; errors = 0; busy = [| 0.; 0. |]; tick = 0. }

let time t name = time_of t.g t.times name
let status t (n : Graph.node) = Option.value (Hashtbl.find_opt t.status n.name) ~default:Notmade
let set_status t (n : Graph.node) s = Hashtbl.replace t.status n.name s
let out_of_date t n a p = Outofdate.arc t.ood n a p

(* run.c's usage(): account for the time since the last change *)
let account t =
  let now = t.io.now () in
  if t.tick > 0. then t.busy.(t.running) <- t.busy.(t.running) +. (now -. t.tick);
  t.tick <- now

(*****************************************************************************)
(* Jobs *)
(*****************************************************************************)

(* mk.c's update(): a job's target is made (or, if it failed, stays
 * being made forever), with its new date stamp *)
let update t (n : Graph.node) ~failed =
  set_status t n (if failed then Beingmade else Made);
  Hashtbl.replace t.times n.name
    (Outofdate.after_recipe t.ood ~exists:t.io.exists ~stat:t.io.stat n)

let touch t (n : Graph.node) =
  if not n.virtual_ then begin
    t.io.print (Printf.sprintf "touch(%s)\n" n.name);
    if not t.flags.dry then t.io.touch n.name
  end
  else if t.flags.explain then t.io.print (Printf.sprintf "no touch of virtual '%s'\n" n.name)

let printed t (j : Recipe.job) ~slot =
  let env = Recipe.env t.mk ~job:j ~slot ~pid:t.io.pid () in
  env, Recipe.shprint t.mk env ~quoting:(Word.quoting_of_shell j.rule.shell) j.rule.recipe

(* run.c's sched(): start the next queued job in a free slot *)
let sched t =
  match Queue.take_opt t.queue with
  | None -> ()
  | Some j ->
      let rec free i = if t.slots.(i) = None then i else free (i + 1) in
      let slot = free 0 in
      let env, text = printed t j ~slot in
      if (not t.flags.touch) && (t.flags.dry || not j.rule.attrs.quiet) then t.io.print text;
      if t.flags.dry || t.flags.touch then
        j.nodes |> List.iter (fun n ->
          if t.flags.touch then touch t n;
          Hashtbl.replace t.times n.name (t.io.now ());
          set_status t n Made)
      else begin
        account t;
        t.slots.(slot) <- Some (t.io.run j ~slot ~env, j);
        t.running <- t.running + 1
      end

let run t (j : Recipe.job) =
  Queue.push j t.queue;
  if t.running < Array.length t.slots then sched t

(* run.c's waitup(): a job ended; false if there was none to wait for *)
let rec waitup t : bool =
  match t.io.wait () with
  | None -> false
  | Some (pid, ended) -> (
      let rec find i =
        if i >= Array.length t.slots then None
        else match t.slots.(i) with
          | Some (p, j) when p = pid -> Some (i, j)
          | _ -> find (i + 1)
      in
      match find 0 with
      | None -> waitup t   (* not one of ours *)
      | Some (slot, j) ->
          account t;
          t.slots.(slot) <- None;
          t.running <- t.running - 1;
          (match ended with
          | Succeeded -> ()
          | Exit_status why ->
              let _, text = printed t j ~slot in
              let b = Buffer.create 80 in
              Printf.bprintf b "mk: %s: exit status=%s" (Recipe.front text) why;
              let deleted = List.filter (fun (n : Graph.node) -> n.delete) j.nodes in
              if deleted <> [] then Buffer.add_string b ", deleting";
              deleted |> List.iter (fun (n : Graph.node) ->
                Printf.bprintf b " '%s'" n.name;
                t.io.delete n.name);
              t.io.eprint (Buffer.contents b ^ "\n");
              if t.flags.keep_going then t.errors <- t.errors + 1
              else (Queue.clear t.queue; raise Failed));
          j.targets |> List.iter (fun name ->
            Option.iter (fun n -> update t n ~failed:(ended <> Succeeded)) (Graph.find t.g name));
          if t.running < Array.length t.slots then sched t;
          true)

(*****************************************************************************)
(* Main algorithm *)
(*****************************************************************************)

(* recipe.c's dorecipe(): queue the job that makes [node] *)
let dorecipe t did (node : Graph.node) =
  let master =
    List.fold_left (fun m (a : Graph.arc) -> if a.rule.recipe <> "" then Some a else m)
      None node.arcs
  in
  match master with
  | None ->
      if node.virtual_ || node.norecipe then begin
        if String.contains node.name '(' && time t node.name = 0. then set_status t node Made
        else update t node ~failed:false;
        if t.flags.touch then touch t node
      end else begin
        t.io.eprint (Printf.sprintf "mk: no recipe to make '%s'\n" node.name);
        raise Failed
      end
  | Some ma ->
      let r = ma.rule in
      (* the rule's other targets that are in the graph and out of date
       * are made by the same job *)
      let nodes, targets, alltargets =
        match ma.stems with
        | Groups _ -> [ node ], [ node.name ], [ node.name ]
        | Exact | Stem _ ->
            let all = List.map (Pattern.subst ma.stems) r.alltargets in
            let others = ref [] and olds = ref [] in
            all |> List.iter (fun tg ->
              match Graph.find t.g tg with
              | None -> ()
              | Some n ->
                  let up_to_date =
                    (not t.flags.always) && time t n.name <> 0.
                    && not (List.exists (fun (a : Graph.arc) ->
                      match a.prereq with Some p -> out_of_date t n a p | None -> false) n.arcs)
                  in
                  if not up_to_date then begin
                    olds := tg :: !olds;
                    if n.name <> node.name then others := n :: !others
                  end);
            node :: !others, List.rev !olds, all
      in
      let prereqs = ref [] and newprereqs = ref [] in
      let add l x = if not (List.mem x !l) then l := x :: !l in
      nodes |> List.iter (fun (n : Graph.node) ->
        n.arcs |> List.iter (fun (a : Graph.arc) ->
          match a.prereq with
          | Some p ->
              add prereqs p.name;
              if out_of_date t n a p then begin
                add newprereqs p.name;
                if t.flags.explain then
                  t.io.print (Printf.sprintf "%s(%.4f) < %s(%.4f)\n"
                                n.name (time t n.name) p.name (time t p.name))
              end
          | None ->
              if t.flags.explain then
                t.io.print (Printf.sprintf "%s has no prerequisites\n" n.name));
        set_status t n Beingmade);
      run t { Recipe.rule = r; stems = ma.stems; targets; alltargets;
              prereqs = List.rev !prereqs; newprereqs = List.rev !newprereqs; nodes };
      did := true

(* mk.c's work(), without the pretending of missing intermediates
 * (principia's default, as -i) *)
let rec work t did (node : Graph.node) =
  if status t node = Notmade then
    if node.arcs = [] then begin
      if time t node.name = 0. then begin
        t.io.eprint (Printf.sprintf "mk: don't know how to make '%s' in %s\n" node.name t.io.cwd);
        if t.flags.keep_going then (set_status t node Beingmade; t.errors <- t.errors + 1)
        else raise Failed
      end
      else set_status t node Made
    end
    else begin
      let outofdate = ref t.flags.always and ready = ref true in
      node.arcs |> List.iter (fun (a : Graph.arc) ->
        match a.prereq with
        | Some p ->
            work t did p;
            if status t p <> Made then ready := false;
            if out_of_date t node a p then outofdate := true
        | None -> if time t node.name = 0. then outofdate := true);
      if !ready then
        if !outofdate then dorecipe t did node
        else (Outofdate.up_to_date t.ood node; set_status t node Made)
    end

let make t ~nproc ~nrep target =
  let nproc = max 1 nproc in
  if nproc > Array.length t.slots then begin
    t.slots <- Array.init nproc (fun i -> if i < Array.length t.slots then t.slots.(i) else None);
    t.busy <- Array.init (nproc + 1) (fun i -> if i < Array.length t.busy then t.busy.(i) else 0.)
  end;
  let root = Graph.node t.g ~nrep target in
  (* mk.c's clrmade(): everything under the target is to be made again;
   * and graph.c's attribute(), which runs for every target, puts a
   * virtual node's time back to 0 *)
  let seen = Hashtbl.create 101 in
  let rec clear (n : Graph.node) =
    if not (Hashtbl.mem seen n.name) then begin
      Hashtbl.replace seen n.name ();
      set_status t n Notmade;
      if n.virtual_ then Hashtbl.replace t.times n.name 0.;
      n.arcs |> List.iter (fun (a : Graph.arc) -> Option.iter clear a.prereq)
    end
  in
  clear root;
  let everdid = ref false in
  let rec loop () =
    if status t root = Notmade then begin
      let did = ref false in
      work t did root;
      if !did then (everdid := true; loop ())
      else if waitup t || status t root = Made then loop ()
    end
  in
  loop ();
  if status t root = Beingmade then ignore (waitup t);
  while not (Queue.is_empty t.queue) do ignore (waitup t) done;
  if not !everdid then t.io.print (Printf.sprintf "mk: '%s' is up to date\n" root.name)

let wait_all t =
  while t.running > 0 && waitup t do () done

let errors t = t.errors

let usage t =
  account t;
  String.concat "" (Array.to_list (Array.mapi (fun i s -> Printf.sprintf "%d: %.0f\n" i s) t.busy))
