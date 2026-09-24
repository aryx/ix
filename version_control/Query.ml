(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Query.mli *)

exception Error of string

let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

let empty_tree = Object.hash (Tree [])

(*****************************************************************************)
(* git9's object set and heap *)
(*****************************************************************************)

type set = { mutable slots : Hash.t option array; mutable n : int }

let new_set () = { slots = Array.make 16 None; n = 0 }

let probe s h = (Int32.to_int (String.get_int32_be (Sha1.raw h) 0) land 0xffffffff) mod Array.length s.slots

let mem s h =
  let rec go i = match s.slots.(i) with None -> false | Some h' -> Hash.compare h h' = 0 || go ((i + 1) mod Array.length s.slots) in
  go (probe s h)

let rec add s h =
  let rec go i = match s.slots.(i) with
    | None -> s.slots.(i) <- Some h; s.n <- s.n + 1; true
    | Some h' -> if Hash.compare h h' = 0 then false else go ((i + 1) mod Array.length s.slots) in
  if go (probe s h) && Array.length s.slots < 2 * s.n then begin
    (* doubled, the old slots put back in their order *)
    let old = s.slots in
    s.slots <- Array.make (2 * Array.length old) None;
    s.n <- 0;
    Array.iter (Option.iter (add s)) old
  end

let elements s = List.filter_map Fun.id (Array.to_list s.slots)

type color = Keep | Drop | Skip

type elt = { h : Hash.t; color : color; time : int }

type heap = { mutable a : elt array; mutable len : int }

let put q e =
  if q.len = Array.length q.a then q.a <- Array.append q.a (Array.make (max 8 q.len) e);
  q.a.(q.len) <- e;
  (* up while not below the parent: an equal time moves up *)
  let rec up i = if i > 0 && not (q.a.(i).time < q.a.((i - 1) / 2).time) then begin
      let t = q.a.(i) in q.a.(i) <- q.a.((i - 1) / 2); q.a.((i - 1) / 2) <- t; up ((i - 1) / 2) end in
  up q.len;
  q.len <- q.len + 1

let pop q =
  let e = q.a.(0) in
  q.len <- q.len - 1;
  if q.len > 0 then begin
    q.a.(0) <- q.a.(q.len);
    let rec down i =
      let m = ref i in
      let l = 2 * i + 1 and r = 2 * i + 2 in
      if l < q.len && q.a.(!m).time < q.a.(l).time then m := l;
      if r < q.len && q.a.(!m).time < q.a.(r).time then m := r;
      if !m <> i then (let t = q.a.(!m) in q.a.(!m) <- q.a.(i); q.a.(i) <- t; down !m) in
    down 0
  end;
  e

(*****************************************************************************)
(* paint *)
(*****************************************************************************)

type mode = Lca | Range | Twixt

let commit (t : Store.t) h : Object.commit option =
  match Store.read t h with Commit c -> Some c | _ -> None | exception Store.Missing _ -> error "read %s: missing" (Hash.to_hex h)

let warn h = prerr_endline (Printf.sprintf "warning: %s does not point at commit" (Hash.to_hex h))

let paint (t : Store.t) heads tails mode =
  let keep = new_set () and drop = new_set () and skip = new_set () in
  let q = { a = [||]; len = 0 } in
  let enqueue color h = match commit t h with
    | Some c -> put q { h; color; time = Object.local_time c.committer }
    | None -> warn h in
  List.iter (fun h -> if Hash.compare h Hash.zero <> 0 then enqueue Keep h) heads;
  List.iter (fun h -> if Hash.compare h Hash.zero <> 0 then enqueue Drop h) tails;
  let range = ref [] in
  while q.len > 0 do
    let e = pop q in
    if not (mem skip e.h) then begin
      let color =
        match e.color with
        | Keep when mem keep e.h -> None
        | Keep ->
            let c = if mem drop e.h then Skip else (if mode = Range then range := e.h :: !range; Keep) in
            add keep e.h; Some c
        | Drop when mem drop e.h -> None
        | Drop -> let c = if mem keep e.h then Skip else Drop in add drop e.h; Some c
        | Skip -> add skip e.h; Some Skip in
      Option.iter (fun color -> match commit t e.h with
        | Some c -> List.iter (enqueue color) c.parents
        | None -> error "not a commit: %s" (Hash.to_hex e.h)) color
    end
  done;
  match mode with
  | Lca -> (match List.find_opt (fun h -> mem drop h && not (mem skip h)) (elements keep) with Some h -> [ h ] | None -> [])
  | Range -> List.filter (fun h -> not (mem drop h) && not (mem skip h)) !range
  | Twixt -> List.filter (fun h -> not (mem drop h) && not (mem skip h)) (elements keep)

let history t h =
  let q = { a = [||]; len = 0 } and seen = Hashtbl.create 64 in
  let enqueue h = match commit t h with
    | Some c -> put q { h; color = Keep; time = Object.local_time c.committer }
    | None -> error "%s: not a commit" (Hash.to_hex h) in
  enqueue h;
  let rec next () =
    if q.len = 0 then Seq.Nil
    else
      let e = pop q in
      let c = Option.get (commit t e.h) in
      List.iter (fun p -> if not (Hashtbl.mem seen p) then (Hashtbl.add seen p (); enqueue p)) c.parents;
      Seq.Cons ((e.h, c), next)
  in
  next

let lca t a b = match paint t [ a ] [ b ] Lca with [ h ] -> Some h | _ -> None
let twixt t heads tails = paint t heads tails Twixt

(*****************************************************************************)
(* The evaluator *)
(*****************************************************************************)

let is_commit t h = Hash.compare h Hash.zero = 0 || (match Store.read t h with Commit _ -> true | _ -> false)

let eval (t : Store.t) (s : string) =
  let n = String.length s in
  let p = ref 0 in
  let stack = ref [] in
  let push h = stack := h :: !stack in
  let pop () = match !stack with h :: rest -> stack := rest; h | [] -> error "stack underflow" in
  let eat_space () = while !p < n && (match s.[!p] with ' ' | '\t' | '\n' | '\r' -> true | _ -> false) do incr p done in
  let is_word = function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '/' | '-' | '_' | '.' -> true | _ -> false in
  let at m = !p + String.length m <= n && String.sub s !p (String.length m) = m in
  let postfix () =
    eat_space ();
    let start = !p in
    while !p < n && is_word s.[!p] && not (at "..") do incr p done;
    let name = String.sub s start (!p - start) in
    if name = "" then error "expected name in expression";
    let h = match Refs.read t name with Some h -> h | None -> error "invalid ref %s" name in
    if Hash.compare h Hash.zero <> 0 && not (Store.mem t h) then error "invalid ref %s (hash %s)" name (Hash.to_hex h);
    push h;
    let rec suffixes () =
      eat_space ();
      if !p < n then
        match s.[!p] with
        | '^' | '~' ->
            incr p;
            let o = pop () in
            (if Hash.compare o Hash.zero = 0 then push empty_tree
             else match Store.read t o with
               | Commit { parents = []; _ } -> push empty_tree
               | Commit { parents = p0 :: _; _ } -> push p0
               | _ -> error "not a commit: %s" (Hash.to_hex o));
            suffixes ()
        | '@' ->
            incr p;
            if List.length !stack < 2 then error "ancestor needs 2 objects";
            let b = pop () in
            let a = pop () in
            (match lca t a b with Some h -> push h | None -> error "no common ancestor");
            suffixes ()
        | _ -> ()
    in
    suffixes ()
  in
  let rec loop () =
    postfix ();
    if !p < n then
      if at ":" || at ".." then begin
        p := !p + (if at ":" then 1 else 2);
        postfix ();
        if !p < n then error "junk at end of expression";
        let b = pop () in
        let a = pop () in
        if not (is_commit t a && is_commit t b) then error "non-commit object in range";
        List.iter push (paint t [ b ] [ a ] Range)
      end
      else loop ()
  in
  loop ();
  List.rev !stack

let eval1 t s = match eval t s with [ h ] -> h | _ -> error "ambiguous ref expr"

(*****************************************************************************)
(* query -c *)
(*****************************************************************************)

let changes (t : Store.t) a b =
  let out = ref [] in
  let print s = out := s :: !out in
  let tree h = match Store.read t h with Tree es -> es | _ -> error "bad hash %s" (Hash.to_hex h) in
  let is_dir (e : Object.entry) = e.mode = Dir || e.mode = Submodule in
  let rec show_dir path h m =
    List.iter (fun (e : Object.entry) ->
      if e.mode = Submodule then ()
      else if e.mode = Dir then show_dir (path ^ e.name ^ "/") e.hash m
      else print (Printf.sprintf "%c %s%s" m path e.name)) (tree h);
    print (Printf.sprintf "%c %s" m path)
  and show path (e : Object.entry) m =
    if is_dir e then (if e.mode = Dir then show_dir (path ^ e.name ^ "/") e.hash m)
    else print (Printf.sprintf "%c %s%s" m path e.name) in
  let rec diff path (xs : Object.entry list) (ys : Object.entry list) =
    match xs, ys with
    | x :: xs', y :: ys' ->
        let c = Object.compare_entries x y in
        if c = 0 then begin
          if not (x.mode = y.mode && Hash.compare x.hash y.hash = 0) then begin
            if x.mode <> y.mode then print ("! " ^ path ^ x.name)
            else if not (is_dir x) || not (is_dir y) then print ("@ " ^ path ^ x.name);
            if x.mode = Dir && y.mode = Dir then diff (path ^ x.name ^ "/") (tree x.hash) (tree y.hash)
          end;
          diff path xs' ys'
        end
        else if c < 0 then (show path x '-'; diff path xs' ys)
        else (show path y '+'; diff path xs ys')
    | xs, [] -> List.iter (fun x -> show path x '-') xs
    | [], ys -> List.iter (fun y -> show path y '+') ys
  in
  let root h = if Hash.compare h Hash.zero = 0 then [] else match Store.read t h with
    | Commit c -> tree c.tree
    | _ -> error "not commit: %s" (Hash.to_hex h) in
  diff "" (root a) (root b);
  List.rev !out
