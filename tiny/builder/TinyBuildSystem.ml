(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny build system: the idea of make (Stuart Feldman, 1976) and mk
 * (Andrew Hume, 1987) -- describe the dependencies between files
 * concisely, and maintain them efficiently -- without their language.
 * TinyMk (builder/) is mk, faithfully; this is what is left when
 * compatibility is dropped and only the idea is kept.
 *
 * A Buildfile has five kinds of lines:
 *
 *     # a comment
 *     OBJS = hello.o world.o          a variable: a list of words
 *     hello: $OBJS                    a rule: targets, then prerequisites
 *         cc -o $target $prereq       its recipe: the lines that start
 *                                     with a blank, run by sh -e
 *     %.o: %.c                        a pattern: % is the stem
 *         cc -c $stem.c
 *     <.depend                        an include
 *
 * and that is all the syntax. Variables are expanded in rule lines as
 * they are read; a recipe gets them, and $target, $prereq and $stem,
 * in its environment, so the shell expands them and there is no second
 * expansion language. There are no attributes: a target whose recipe
 * makes no file (clean, all) is simply never up to date.
 *
 * {b Up to date by content, not by time.} Each target's stamp is a
 * digest of its recipe and of its prerequisites' contents:
 *
 *     stamp(hello) = md5(recipe, "hello.o", md5(hello.o), "world.o", ...)
 *
 * The stamps of the last build are kept in .tinybuild; a target is
 * rebuilt when it is missing or its stamp changed. That is the
 * "verifying traces" rebuilder of Mokhov, Mitchell and Peyton Jones,
 * "Build Systems a la Carte" (2018), and it removes three of mk's
 * problems at once: two files made in the same second are not "equal",
 * a git checkout's new times rebuild nothing, and a recipe that
 * regenerates an identical file stops the rebuild there (early cutoff)
 * without mk's cmp -s trick.
 *
 * {b One pass, no re-walk.} mk walks its whole graph again after every
 * job, because a recipe's effect is known only by looking at the file
 * again. Here a node is decided when it becomes ready -- when all its
 * prerequisites are done and their digests known -- so one topological
 * pass does, with -j N jobs at a time (Kahn, 1962, as a scan of the
 * nodes left: the simple version, quadratic, fine for hundreds):
 *
 *     todo  = the nodes under the target, prerequisites first
 *     loop: start every todo node whose prerequisites are done,
 *             while fewer than N jobs run
 *           a node that is up to date, or has no recipe, is done now
 *           otherwise wait for a job to end; its node is done
 *
 * {b What it checks}, before running anything: a cycle (reported with
 * its path, a -> b -> a), two pattern rules that could both make a
 * target (ambiguous), a target nothing knows how to make, and infinite
 * patterns (%: %.gz is used at most once on a path).
 *
 * <file includes a file, if it exists (a generated .depend may not, the
 * first time), and a backslash-newline continues a line, as ocamldep
 * writes them: that is enough for a Buildfile of 13 lines to build
 * TinyMk's ten modules from ocamldep's output, with -j 4 in about a
 * second. There, a comment added to Recipe.ml recompiles Recipe.ml
 * only: its object comes out identical, so nothing is relinked.
 *
 * What it deliberately does not do, to stay tiny: quoting (names cannot
 * contain blanks), ${X:%.c=%.o} substitutions, one recipe
 * making several targets at once (a b: c runs the recipe once per
 * target), archives, and mk's -t, -w, -k, -e. The digests are
 * recomputed at each run, reading every input: the price of not
 * trusting times. A file named like a virtual target (a file "clean")
 * makes it look like a real one.
 *
 * Usage: tinybuild [-f Buildfile] [-j N] [-n] [-g] [target ...]
 *   -n prints the recipes that would run, -g prints the graph for dot.
 *
 * Exercises: add ${X:%.c=%.o}; make the stamp of a source file its
 * (mtime, size) when unchanged since the last run, to avoid reading
 * it again; replace the scan by pending counts per node and measure
 * the difference; let a recipe declare the dependencies it discovered
 * (redo's redo-ifchange), which the one-pass scheduler can take if a
 * node is decided again after its new prerequisites are done. *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type rule = {
  target : string;         (* may contain one %, the stem *)
  prereqs : string list;
  recipe : string;         (* "" when none *)
}

type node = {
  name : string;
  deps : node list;
  recipe : string;
  stem : string;
}

exception Error of string

let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

(*****************************************************************************)
(* Reading a Buildfile *)
(*****************************************************************************)

let words (s : string) : string list =
  String.split_on_char ' ' (String.map (fun c -> if c = '\t' then ' ' else c) s)
  |> List.filter (( <> ) "")

(* $X and ${X}, by the value of X; an unknown X is an error, or, when
 * printing a recipe, left for the shell *)
let expand ?(keep = false) (vars : (string, string list) Hashtbl.t) (s : string) : string =
  let is_name c = c = '_' || ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9') in
  let b = Buffer.create (String.length s) and n = String.length s in
  let rec go i =
    if i < n then
      if s.[i] = '$' && i + 1 < n then begin
        let braced = s.[i + 1] = '{' in
        let j = ref (if braced then i + 2 else i + 1) in
        while !j < n && is_name s.[!j] do incr j done;
        let start = if braced then i + 2 else i + 1 in
        let name = String.sub s start (!j - start) in
        let value =
          match Hashtbl.find_opt vars name with
          | Some v -> String.concat " " v
          | None when keep -> String.sub s i ((if braced then !j + 1 else !j) - i)
          | None -> error "undefined variable $%s" name
        in
        Buffer.add_string b value;
        go (if braced then !j + 1 else !j)
      end
      else (Buffer.add_char b s.[i]; go (i + 1))
  in
  go 0;
  Buffer.contents b

(* the rules, in order, and the variables; [read] gives an included
 * file's text (None: it doesn't exist yet, e.g. a generated .depend) *)
let parse ~(read : string -> string option) (text : string) :
    rule list * (string, string list) Hashtbl.t =
  let vars = Hashtbl.create 17 and rules = ref [] in
  (* a backslash-newline continues a line, as ocamldep writes them *)
  let lines text =
    let n = String.length text and b = Buffer.create (String.length text) in
    String.iteri (fun i c ->
      if c = '\\' && i + 1 < n && text.[i + 1] = '\n' then Buffer.add_char b ' '
      else if not (c = '\n' && i > 0 && text.[i - 1] = '\\') then Buffer.add_char b c) text;
    String.split_on_char '\n' (Buffer.contents b)
  in
  let is_recipe l = l <> "" && (l.[0] = '\t' || l.[0] = ' ') in
  let strip l = match String.index_opt l '#' with Some i -> String.sub l 0 i | None -> l in
  let rec go = function
    | [] -> ()
    | l :: _ when is_recipe l -> error "a recipe line with no rule: %s" l
    | l :: rest when String.length l > 1 && l.[0] = '<' ->
        let file = String.trim (expand vars (String.sub l 1 (String.length l - 1))) in
        Option.iter (fun text -> go (lines text)) (read file);
        go rest
    | l :: rest ->
        let l = strip l in
        let before i = words (expand vars (String.sub l 0 i)) in
        let after i = words (expand vars (String.sub l (i + 1) (String.length l - i - 1))) in
        (* whichever of = and : comes first *)
        match String.index_opt l '=', String.index_opt l ':' with
        | Some i, j when (match j with Some j -> i < j | None -> true) ->
            Hashtbl.replace vars (String.trim (String.sub l 0 i)) (after i);
            go rest
        | _, Some j ->
            let rec recipe acc = function
              | r :: rs when is_recipe r -> recipe (String.trim r :: acc) rs
              | rs -> String.concat "\n" (List.rev acc), rs
            in
            let body, rest = recipe [] rest in
            let prereqs = after j in
            before j |> List.iter (fun target -> rules := { target; prereqs; recipe = body } :: !rules);
            go rest
        | _ ->
            if String.trim l <> "" then error "not a rule nor a variable: %s" l;
            go rest
  in
  go (lines text);
  List.rev !rules, vars

(*****************************************************************************)
(* The graph *)
(*****************************************************************************)

(* does pattern p (with one %) match name? the stem if so *)
let matches (p : string) (name : string) : string option =
  match String.index_opt p '%' with
  | None -> if p = name then Some "" else None
  | Some i ->
      let pre = String.sub p 0 i and suf = String.sub p (i + 1) (String.length p - i - 1) in
      let n = String.length name and np = String.length pre and ns = String.length suf in
      if np + ns <= n && String.sub name 0 np = pre && String.sub name (n - ns) ns = suf
      then Some (String.sub name np (n - np - ns)) else None

let subst stem (p : string) = String.concat stem (String.split_on_char '%' p)

(* From a target to its node: the rules naming it exactly, merged (at
 * most one with a recipe); if none has a recipe, the one pattern rule
 * whose prerequisites can all be made. *)
let graph (rules : rule list) ~(exists : string -> bool) (target : string) : node =
  let memo = Hashtbl.create 101 in
  let exact, patterns = List.partition (fun r -> not (String.contains r.target '%')) rules in
  let rec node path used name =
    match Hashtbl.find_opt memo name with
    | Some n -> n
    | None ->
        if List.mem name path then
          error "cycle: %s" (String.concat " -> " (List.rev (name :: path)));
        let mine = List.filter (fun r -> r.target = name) exact in
        let prereqs = List.concat_map (fun r -> r.prereqs) mine in
        let recipe, stem, extra, used =
          match List.filter (fun (r : rule) -> r.recipe <> "") mine with
          | [ r ] -> r.recipe, "", [], used
          | _ :: _ :: _ -> error "two recipes for %s" name
          | [] ->
              let candidates =
                patterns |> List.filter_map (fun r ->
                  if List.memq r used then None
                  else match matches r.target name with
                    | Some stem when List.for_all (makeable path (r :: used)) (List.map (subst stem) r.prereqs)
                      -> Some (r, stem)
                    | _ -> None)
              in
              (match candidates with
               | [] -> "", "", [], used
               | [ (r, stem) ] -> r.recipe, stem, List.map (subst stem) r.prereqs, r :: used
               | _ -> error "ambiguous: several patterns make %s" name)
        in
        let n = { name; recipe; stem; deps = List.map (node (name :: path) used) (prereqs @ extra) } in
        if recipe = "" && n.deps = [] && not (exists name) then error "don't know how to make %s" name;
        Hashtbl.replace memo name n;
        n
  (* can this name be made: a file, or a target of some rule? *)
  and makeable path used name =
    exists name || List.exists (fun r -> r.target = name) exact
    || List.exists (fun r ->
         not (List.memq r used) && not (List.mem name path)
         && match matches r.target name with
            | Some stem -> List.for_all (makeable (name :: path) (r :: used)) (List.map (subst stem) r.prereqs)
            | None -> false) patterns
  in
  node [] [] target

(* the nodes under [root], each once, prerequisites first *)
let order (root : node) : node list =
  let seen = Hashtbl.create 101 and out = ref [] in
  let rec go n =
    if not (Hashtbl.mem seen n.name) then begin
      Hashtbl.replace seen n.name ();
      List.iter go n.deps;
      out := n :: !out
    end
  in
  go root;
  List.rev !out

(*****************************************************************************)
(* The outside world *)
(*****************************************************************************)

let read_file (caps : < Cap.open_in; .. >) (file : string) : string option =
  if not (Sys.file_exists file) then None
  else
    let ic = CapStdlib.open_in caps file in
    let s = really_input_string ic (in_channel_length ic) in
    close_in ic;
    Some s

let digest_file (_ : < Cap.open_in; .. >) (file : string) : string option =
  if Sys.file_exists file && not (Sys.is_directory file) then Some (Digest.to_hex (Digest.file file))
  else None

let start (caps : < Cap.fork; Cap.exec; .. >) (env : string array) (recipe : string) : int =
  match CapUnix.fork caps () with
  | 0 ->
      (try CapUnix.execve caps "/bin/sh" [| "sh"; "-e"; "-c"; recipe |] env with _ -> ());
      Unix._exit 127
  | pid -> pid

(*****************************************************************************)
(* Building *)
(*****************************************************************************)

let stampfile = ".tinybuild"

let build (caps : < Cap.fork; Cap.exec; Cap.wait; Cap.open_in; Cap.env; .. >)
    ~(vars : (string, string list) Hashtbl.t) ~(stamps : (string, string) Hashtbl.t)
    ~jobs ~dry (root : node) : bool =
  let digests = Hashtbl.create 101 in    (* the nodes done: their digest *)
  let running = Hashtbl.create 7 in      (* pid -> node *)
  let ran = ref 0 and failed = ref false in
  let env =
    Array.to_list (CapUnix.environment caps ())
    @ Hashtbl.fold (fun k v acc -> (k ^ "=" ^ String.concat " " v) :: acc) vars []
  in
  let stamp n =
    Digest.to_hex (Digest.string (String.concat "\n" (n.recipe :: List.map (fun d ->
      d.name ^ " " ^ Hashtbl.find digests d.name) n.deps)))
  in
  (* a node is done: its digest is its file's, or, without one, its stamp *)
  let finish n = Hashtbl.replace digests n.name
      (match digest_file caps n.name with Some d -> d | None -> stamp n) in
  let decide n =
    if n.recipe = "" then finish n
    else if digest_file caps n.name <> None && Hashtbl.find_opt stamps n.name = Some (stamp n) then
      finish n
    else begin
      let own = [ "target", [ n.name ]; "stem", [ n.stem ]; "prereq", List.map (fun d -> d.name) n.deps ] in
      let shown = Hashtbl.copy vars in
      List.iter (fun (k, v) -> Hashtbl.replace shown k v) own;
      print_endline (expand ~keep:true shown n.recipe);
      incr ran;
      if dry then Hashtbl.replace digests n.name ("dry " ^ n.name)
      else
        let own = List.map (fun (k, v) -> k ^ "=" ^ String.concat " " v) own in
        Hashtbl.replace running (start caps (Array.of_list (own @ env)) n.recipe) n
    end
  in
  let wait () =
    let pid, st = CapUnix.wait caps () in
    match Hashtbl.find_opt running pid with
    | None -> ()
    | Some n ->
        Hashtbl.remove running pid;
        if st = Unix.WEXITED 0 then (Hashtbl.replace stamps n.name (stamp n); finish n)
        else (Printf.eprintf "tinybuild: %s failed\n%!" n.name; failed := true)
  in
  let rec loop todo =
    let ready n = List.for_all (fun d -> Hashtbl.mem digests d.name) n.deps in
    let rec start_ready = function
      | n :: rest when Hashtbl.length running < jobs && not !failed && ready n ->
          decide n; start_ready rest
      | n :: rest -> n :: start_ready rest
      | [] -> []
    in
    let todo = start_ready todo in
    if Hashtbl.length running > 0 then (wait (); loop todo)
    else if todo <> [] && not !failed && List.exists ready todo then loop todo
  in
  loop (order root);
  if !ran = 0 && not !failed then Printf.printf "tinybuild: %s is up to date\n" root.name;
  not !failed

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let main (caps : Cap.all_caps) : int =
  let file = ref "Buildfile" and jobs = ref 1 and dry = ref false and dot = ref false in
  let targets = ref [] in
  Arg.parse_argv (CapSys.argv caps)
    [ "-f", Arg.Set_string file, " the Buildfile";
      "-j", Arg.Set_int jobs, " how many recipes at once";
      "-n", Arg.Set dry, " print the recipes, run nothing";
      "-g", Arg.Set dot, " print the graph, for dot" ]
    (fun t -> targets := !targets @ [ t ]) "tinybuild [-f file] [-j N] [-n] [-g] [target ...]";
  try
    let text = match read_file caps !file with Some s -> s | None -> error "no %s" !file in
    let rules, vars = parse ~read:(read_file caps) text in
    let targets =
      match !targets, rules with
      | [], r :: _ -> [ r.target ]
      | [], [] -> error "nothing to build"
      | ts, _ -> ts
    in
    let stamps = Hashtbl.create 101 in
    Option.iter (fun s ->
      String.split_on_char '\n' s |> List.iter (fun l ->
        match String.split_on_char ' ' l with
        | [ name; st ] -> Hashtbl.replace stamps name st
        | _ -> ())) (read_file caps stampfile);
    let ok =
      List.for_all (fun t ->
        let root = graph rules ~exists:Sys.file_exists t in
        if !dot then begin
          print_endline "digraph G {";
          order root |> List.iter (fun n ->
            List.iter (fun d -> Printf.printf "  %S -> %S;\n" n.name d.name) n.deps);
          print_endline "}";
          true
        end
        else build caps ~vars ~stamps ~jobs:(max 1 !jobs) ~dry:!dry root) targets
    in
    if not !dry then begin
      let oc = open_out stampfile in
      Hashtbl.iter (fun k v -> Printf.fprintf oc "%s %s\n" k v) stamps;
      close_out oc
    end;
    if ok then 0 else 1
  with Error msg -> Printf.eprintf "tinybuild: %s\n" msg; 1

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
