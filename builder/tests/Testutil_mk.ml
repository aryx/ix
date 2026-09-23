(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* Helpers for the tests: a mkfile read from a string, and a fake world
 * -- files with times and contents, and recipes that run instantly --
 * for Build, so that whole builds run without a disk, a shell or a
 * clock, deterministically. *)
open Ix_mk

(*****************************************************************************)
(* Reading *)
(*****************************************************************************)

(* a mkfile from [text]; [files] are what <file finds; a backquote's
 * output is its command, uppercased *)
let mkfile ?(files = []) ?(env = []) ?(args = []) (text : string) : Mkfile.t =
  let mk = Mkfile.create ~env ~default_shell:[ "sh" ] in
  let io : Mkfile.io = {
    read_file = (fun f -> List.assoc_opt f files);
    output = (fun _ ~shell:_ ~stdin:_ cmd -> String.uppercase_ascii (String.trim cmd), true);
    warn = (fun _ -> ());
  } in
  if args <> [] then
    Mkfile.read ~override:true io mk ~file:"<command line args>"
      (String.concat "" (List.map (fun a -> a ^ "\n") args));
  Mkfile.read io mk ~file:"mkfile" text;
  mk

(* the prerequisites of a node, by name *)
let prereqs (n : Graph.node) : string list =
  List.filter_map (fun (a : Graph.arc) -> Option.map (fun (p : Graph.node) -> p.name) a.prereq) n.arcs

(*****************************************************************************)
(* A fake world *)
(*****************************************************************************)

(* A recipe here makes each target's content "target(contents of its
 * prerequisites)", or, for one listed in [constant], "target" whatever
 * its inputs (a generated header that came out the same); one listed
 * in [cutoff] leaves its file alone when its content would not change
 * (the cmp -s trick). *)
type world = {
  files : (string, float * string) Hashtbl.t;   (* time, content *)
  mutable clock : float;
  mutable ran : string list;                     (* jobs, by their first target, reversed *)
  mutable running : (int * Recipe.job) list;     (* oldest last *)
  mutable next_pid : int;
  mutable violations : string list;              (* started before a prereq was made *)
  mutable out : string;
  order : Random.State.t option;                 (* None: jobs end in the order they started *)
  cutoff : string list;
  constant : string list;
}

let world ?order ?(cutoff = []) ?(constant = []) (leaves : string list) : world =
  let w = {
    files = Hashtbl.create 17; clock = 1.; ran = []; running = []; next_pid = 100;
    violations = []; out = ""; order; cutoff; constant;
  } in
  leaves |> List.iter (fun l -> Hashtbl.replace w.files l (1., l));
  w

let content w name = Option.map snd (Hashtbl.find_opt w.files name)

let tick w = w.clock <- w.clock +. 1.; w.clock

(* change a leaf, as an editor would *)
let edit w name = Hashtbl.replace w.files name (tick w, name ^ "'")

let finish w (j : Recipe.job) =
  let input = String.concat "," (List.map (fun p -> Option.value (content w p) ~default:"?") j.prereqs) in
  j.targets |> List.iter (fun t ->
    let virtual_ =
      match List.find_opt (fun (n : Graph.node) -> n.name = t) j.nodes with
      | Some n -> n.virtual_ | None -> false
    in
    let c = if List.mem t w.constant then t else t ^ "(" ^ input ^ ")" in
    if not virtual_ && not (List.mem t w.cutoff && content w t = Some c) then
      Hashtbl.replace w.files t (tick w, c))

let io (w : world) : Build.io = {
  run = (fun j ~slot:_ ~env:_ ->
    let busy = List.concat_map (fun (_, (r : Recipe.job)) -> r.targets) w.running in
    j.prereqs |> List.iter (fun p ->
      if List.mem p busy then w.violations <- (List.hd j.targets ^ " before " ^ p) :: w.violations);
    w.ran <- List.hd j.targets :: w.ran;
    w.next_pid <- w.next_pid + 1;
    w.running <- (w.next_pid, j) :: w.running;
    w.next_pid);
  wait = (fun () ->
    match List.rev w.running with
    | [] -> None
    | oldest :: _ as all ->
        let (pid, j) =
          match w.order with
          | None -> oldest
          | Some st -> List.nth all (Random.State.int st (List.length all))
        in
        w.running <- List.filter (fun (p, _) -> p <> pid) w.running;
        finish w j;
        Some (pid, ""));
  stat = (fun name -> match Hashtbl.find_opt w.files name with Some (t, _) -> t | None -> 0.);
  exists = Hashtbl.mem w.files;
  touch = (fun name ->
    let c = Option.value (content w name) ~default:"" in
    Hashtbl.replace w.files name (tick w, c));
  delete = Hashtbl.remove w.files;
  prog = (fun _ _ _ -> true);
  now = (fun () -> tick w);
  print = (fun s -> w.out <- w.out ^ s);
  eprint = (fun s -> w.out <- w.out ^ s);
  cwd = "/fake";
  pid = 1;
}

let flags = { Build.dry = false; touch = false; always = false; keep_going = false; explain = false }

(* -H in the fake world: a file's digest is its content *)
let hashes (w : world) : Outofdate.hashes =
  { digest = (fun name -> content w name); traces = Hashtbl.create 17 }

(* [build w mk target]: a whole mk run in the fake world; the jobs run,
 * in order, by their first target *)
let build ?(nproc = 1) ?(flags = flags) ?hashes (w : world) (mk : Mkfile.t) (target : string) : string list =
  w.ran <- [];
  w.out <- "";
  let stat name = match Hashtbl.find_opt w.files name with Some (t, _) -> t | None -> 0. in
  let g = Graph.create mk ~stat in
  let b = Build.create ?hashes mk g (io w) flags in
  Build.make b ~nproc ~nrep:1 target;
  List.rev w.ran

(*****************************************************************************)
(* Random graphs *)
(*****************************************************************************)

(* A random DAG from a seed: targets t0..t(n-1), each depending on one
 * to three of the leaves l0..l(k-1) and of the targets after it, and a
 * virtual "all" depending on every target. Returns the mkfile's text,
 * the leaves, and each target's prerequisites. *)
let random_dag (seed : int) ~(targets : int) ~(leaves : int) =
  let st = Random.State.make [| seed |] in
  let leaf i = Printf.sprintf "l%d" i and target i = Printf.sprintf "t%d" i in
  let deps =
    List.init targets (fun i ->
      let pool = List.init leaves leaf @ List.init (targets - i - 1) (fun j -> target (i + 1 + j)) in
      let pick () = List.nth pool (Random.State.int st (List.length pool)) in
      let ps = List.sort_uniq compare (List.init (1 + Random.State.int st 3) (fun _ -> pick ())) in
      target i, ps)
  in
  let text =
    "all:V: " ^ String.concat " " (List.map fst deps) ^ "\n\techo all\n"
    ^ String.concat "" (List.map (fun (t, ps) ->
        Printf.sprintf "%s: %s\n\tmake %s\n" t (String.concat " " ps) t) deps)
  in
  text, List.init leaves leaf, deps

(* what a clean build makes: each target's content from its
 * prerequisites', recursively (the "correct" law's oracle) *)
let rec expected deps (w0 : world) name =
  match List.assoc_opt name deps with
  | None -> Option.value (content w0 name) ~default:"?"
  | Some ps -> name ^ "(" ^ String.concat "," (List.map (expected deps w0) ps) ^ ")"

(* the targets that depend on [leaf], directly or not *)
let dependents deps leaf =
  let rec depends t =
    match List.assoc_opt t deps with
    | None -> false
    | Some ps -> List.mem leaf ps || List.exists depends ps
  in
  List.filter depends (List.map fst deps)
