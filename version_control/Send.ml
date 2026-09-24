(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Send.mli *)

type opts = { all : bool; force : bool; branches : string list; removed : string list }

let error fmt = Printf.ksprintf (fun s -> raise (Proto.Error s)) fmt

type map = { ref : string; ours : Hash.t; mutable theirs : Hash.t }

let send (st : Store.t) (c : Proto.conn) o ~print ~eprint =
  let ours =
    if o.all then List.map (fun (n, h) -> n, h) (Refs.list st)
    else begin
      let branches = List.map (fun b -> b, (try Query.eval1 st b with Query.Error _ -> error "broken branch %s" b)) o.branches in
      List.fold_left (fun acc r ->
        let pfx =
          if String.starts_with ~prefix:"refs/heads/" r then ""
          else if String.starts_with ~prefix:"heads/" r then "refs/"
          else "refs/heads/" in
        let name = pfx ^ r in
        if List.mem_assoc name acc then List.map (fun (n, h) -> if n = name then n, Hash.zero else n, h) acc
        else acc @ [ name, Hash.zero ]) branches o.removed
    end in
  let map = List.map (fun (ref, ours) -> { ref; ours; theirs = Hash.zero }) ours in
  let theirs = ref [] and first = ref true in
  let rec advert () =
    match Proto.read_pkt c with
    | Flush -> ()
    | Pkt buf ->
        let line = Get.cut_nul buf in
        if !first && String.length buf > String.length line then
          Proto.parse_caps c (String.sub buf (String.length line + 1) (String.length buf - String.length line - 1));
        first := false;
        (match Get.fields " \t\r\n" line with
         | [ h; name ] ->
             let h = match Get.hparse h with Some h -> h | None -> error "invalid hash %s" h in
             List.iter (fun m -> if m.ref = name then m.theirs <- h) map;
             (* kept only if we have it: it is what they need not get *)
             if Store.mem st h then theirs := h :: !theirs
         | _ -> error "invalid ref line %s" line);
        advert () in
  advert ();
  let theirs = List.rev !theirs in
  let send = ref o.force in
  List.iteri (fun i m ->
    let is_zero h = Hash.compare h Hash.zero = 0 in
    let a = if (not (is_zero m.theirs)) && Store.mem st m.theirs then Some m.theirs else None in
    let p = match a with Some a when not (is_zero m.ours) -> Query.lca st a m.ours | _ -> None in
    if (not o.force) && (not (is_zero m.theirs)) && (not (is_zero m.ours)) && (a = None || p <> a) then begin
      eprint "remote has diverged\n";
      Proto.flush c;
      error "remote diverged"
    end;
    if Hash.compare m.theirs m.ours = 0 then print (Printf.sprintf "uptodate %s\n" m.ref)
    else begin
      print (Printf.sprintf "update %s %s %s\n" m.ref (Hash.to_hex m.theirs) (Hash.to_hex m.ours));
      (* github wants a capability to update the references *)
      let caps = if i = 0 && c.report then "\000 report-status" else "" in
      Proto.write_pkt c (Printf.sprintf "%s %s %s%s" (Hash.to_hex m.theirs) (Hash.to_hex m.ours) m.ref caps);
      send := true
    end) map;
  Proto.flush c;
  if not !send then eprint "nothing to send\n"
  else begin
    Proto.write_raw c (Packer.pack st ~heads:(List.map (fun m -> m.ours) map) ~have:theirs);
    if c.report then begin
      let rec status () =
        match Proto.read_pkt c with
        | Flush -> ()
        | Pkt buf -> (
            match Get.fields " \t\n\r" buf with
            | "unpack" :: st :: _ when st <> "ok" -> error "unpack %s" st
            | "ng" :: r :: rest -> error "failed update: %s %s" r (String.concat " " rest)
            | _ -> status ()) in
      status ()
    end
  end
