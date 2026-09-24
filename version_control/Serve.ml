(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Serve.mli *)

exception Fatal of string

(* an error for the client, and git9's sysfatal *)
let fail c fmt = Printf.ksprintf (fun s -> (try Proto.write_pkt c ("ERR " ^ s ^ "\n") with _ -> ()); raise (Fatal s)) fmt

let showrefs (st : Store.t) c =
  let head, name =
    match Files.read_opt st.caps Fpath.(st.git / "HEAD") with
    | Some s when String.starts_with ~prefix:"ref: " (String.trim s) ->
        let n = String.trim (String.sub (String.trim s) 5 (String.length (String.trim s) - 5)) in
        (match (try Some (Query.eval1 st n) with Query.Error _ -> None) with
         | Some h -> h, n
         | None -> Hash.zero, "<nil>")
    | _ -> Hash.zero, "<nil>" in
  Proto.write_pkt c (Printf.sprintf "%s HEAD\000symref=HEAD:%s no-thin\n" (Hash.to_hex head) name);
  List.iter (fun (n, h) -> if String.starts_with ~prefix:"heads/" n then Proto.write_pkt c (Printf.sprintf "%s refs/%s\n" (Hash.to_hex h) n)) (Refs.list st);
  Proto.flush c

let upload (st : Store.t) c =
  showrefs st c;
  let parse what pkt =
    match Get.hparse (String.sub pkt 5 (String.length pkt - 5)) with
    | Some h -> h
    | None -> fail c " garbled %s" what in
  let heads = ref [] in
  let rec wants () =
    match Proto.read_pkt c with
    | Flush -> ()
    | Pkt p ->
        if not (String.starts_with ~prefix:"want " p) then fail c " protocol garble %s" p;
        let h = parse "want" p in
        if not (Store.mem st h) then fail c "requested nonexistent object";
        heads := h :: !heads;
        wants () in
  wants ();
  (* the haves; a flush answered by NAK, and the buffer read again, as
   * git9's is (readpkt leaves it as it was) *)
  let tails = ref [] and acked = ref false and last = ref "" in
  let rec haves () =
    let pkt = match Proto.read_pkt c with
      | Flush -> if not !acked then Proto.write_pkt c "NAK"; !last
      | Pkt p -> last := p; p in
    if not (String.starts_with ~prefix:"done" pkt) then begin
      if not (String.starts_with ~prefix:"have " pkt) then fail c " protocol garble %s" pkt;
      let h = parse "have" pkt in
      if Store.mem st h then begin
        if not !acked then (Proto.write_pkt c ("ACK " ^ Hash.to_hex h); acked := true);
        tails := h :: !tails
      end;
      haves ()
    end in
  haves ();
  if not !acked then Proto.write_pkt c "NAK\n";
  Proto.write_raw c (Packer.pack st ~heads:(List.rev !heads) ~have:(List.rev !tails))

let receive (st : Store.t) c =
  showrefs st c;
  let updates = ref [] in
  let rec negotiate () =
    match Proto.read_pkt c with
    | Flush -> ()
    | Pkt pkt ->
        (match Get.fields " \t\n\r" (Get.cut_nul pkt) with
         | [ o; n; r ] ->
             let old = match Get.hparse o with Some h -> h | None -> fail c "bad old hash %s" o in
             let upd = match Get.hparse n with Some h -> h | None -> fail c "bad new hash %s" n in
             let r = Repo.cleanname r in
             if not (String.starts_with ~prefix:"refs/" r && Proto.okref r) then fail c "invalid ref %s" r;
             let path = Filename.concat (Filename.dirname (Fpath.to_string st.git)) (".git/" ^ r) in
             if Sys.file_exists path && (try Unix.access path [ Unix.W_OK ]; false with Unix.Unix_error _ -> true) then
               fail c "read-only ref %s" r;
             updates := (old, upd, r) :: !updates
         | _ -> fail c " protocol garble %s" pkt);
        negotiate () in
  negotiate ();
  let updates = List.rev !updates in
  if updates <> [] then begin
    (* the pack, to the end of the input *)
    let b = Buffer.create 65536 in
    let rec read () = let s = Proto.read_raw c 65536 in if s <> "" then (Buffer.add_string b s; read ()) in
    read ();
    (try ignore (Store.add_pack st ~warn:prerr_string (Buffer.contents b))
     with Object.Corrupt m -> raise (Fatal ("update pack: " ^ m)));
    (* the references, under the lock *)
    let lock = Fpath.to_string Fpath.(st.git / "_lock") in
    let rec take n =
      match Unix.openfile lock [ Unix.O_CREAT; Unix.O_EXCL; Unix.O_RDWR ] 0o644 with
      | fd -> Unix.close fd
      | exception Unix.Unix_error _ -> if n = 0 then raise (Fatal "update refs: repo locked") else (Unix.sleepf 0.25; take (n - 1)) in
    take 9;
    let release () = try Sys.remove lock with Sys_error _ -> () in
    let err fmt = Printf.ksprintf (fun s -> release (); (try Proto.write_pkt c ("ERR " ^ s) with _ -> ()); raise (Fatal ("update refs: " ^ s))) fmt in
    let hadref = ref false and newest = ref None in
    List.iter (fun (old, upd, r) ->
      (match (try Some (Query.eval1 st r) with Query.Error _ -> None) with
       | Some h -> hadref := true; if Hash.compare h old <> 0 then err "old ref changed: %s" r
       | None -> ());
      if Hash.compare upd Hash.zero = 0 then Refs.remove st r
      else begin
        (match Store.read st upd with
         | Commit cm ->
             let t = Object.local_time cm.author in
             (match !newest with Some (t', _) when t' >= t -> () | _ -> newest := Some (t, r))
         | _ -> err "not commit: %s" (Hash.to_hex upd)
         | exception Store.Missing _ -> err "update to nonexistent hash %s" (Hash.to_hex upd));
        Refs.write st r upd
      end) updates;
    if Refs.read st "HEAD" = None && not !hadref then
      Option.iter (fun (_, r) -> Refs.write_symbolic st "HEAD" r) !newest;
    release ()
  end

let serve caps ~allow_write ~prefix c =
  let buf = match Proto.read_pkt c with Pkt p -> p | Flush -> raise (Fatal "readpkt: flush") in
  let buf = Get.cut_nul buf in
  let cmd, repo = match String.index_opt buf ' ' with
    | Some i -> String.sub buf 0 i, String.trim (String.sub buf i (String.length buf - i))
    | None -> buf, "" in
  let repo = Repo.cleanname repo in
  if String.starts_with ~prefix:"../" repo || repo = ".." then fail c "invalid path %s\n" repo;
  let path = match prefix with Some p -> Repo.cleanname (p ^ "/" ^ repo) | None -> repo in
  if not (Sys.file_exists (Filename.concat path ".git")) then fail c "no such repo: %s" repo;
  let st = Store.open_git caps (Fpath.v (Filename.concat path ".git")) in
  match cmd with
  | "git-receive-pack" -> if not allow_write then fail c "read-only repo"; receive st c
  | "git-upload-pack" -> upload st c
  | _ -> fail c "unsupported command '%s'" cmd
