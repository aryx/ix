(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Get.mli *)

type opts = { upstream : string; heads : Hash.t list; listonly : bool; branch : string option }

let error fmt = Printf.ksprintf (fun s -> raise (Proto.Error s)) fmt

let hparse s = if String.length s >= 40 && Hash.is_hex (String.sub s 0 40) then Some (Hash.of_hex (String.sub s 0 40)) else None

(* a remote reference's local copy *)
let rec resolveremote (st : Store.t) upstream ref =
  let ref = String.trim ref in
  match hparse ref with
  | Some h -> Some h
  | None ->
      let file =
        if ref = "HEAD" then Some ".git/HEAD"
        else if String.starts_with ~prefix:"refs/heads" ref then Some (Printf.sprintf ".git/refs/remotes/%s/%s" upstream (String.sub ref 10 (String.length ref - 10)))
        else if String.starts_with ~prefix:"refs/tags" ref then Some (Printf.sprintf ".git/refs/tags/%s/%s" upstream (String.sub ref 9 (String.length ref - 9)))
        else None in
      Option.bind file (fun f ->
        let path = Filename.concat (Filename.dirname (Fpath.to_string st.git)) f in
        match Files.read_opt st.caps (Fpath.v path) with
        | None -> None
        | Some s -> (
            match (if String.length s >= 40 then hparse s else None) with
            | Some h -> Some h
            | None -> if String.starts_with ~prefix:"ref:" s then resolveremote st upstream (String.sub s 4 (String.length s - 4)) else None))

let branchmatch br pat =
  let name =
    if String.starts_with ~prefix:"refs/heads" pat then pat
    else if String.starts_with ~prefix:"heads/" pat then "refs/" ^ pat
    else "refs/heads/" ^ pat in
  br = name

(* the fields of a line split at blanks, empty ones dropped *)
let fields seps s = List.filter (( <> ) "") (String.split_on_char ' ' (String.map (fun c -> if String.contains seps c then ' ' else c) s))

let cut_nul s = match String.index_opt s '\000' with Some i -> String.sub s 0 i | None -> s

let fetch (st : Store.t) (c : Proto.conn) o ~print ~eprint =
  (* the references *)
  let refs = ref [] and first = ref true in
  let rec advert () =
    match Proto.read_pkt c with
    | Flush -> ()
    | Pkt buf ->
        let line = cut_nul buf in
        if !first && String.length buf > String.length line then begin
          Proto.parse_caps c (String.sub buf (String.length line + 1) (String.length buf - String.length line - 1));
          Option.iter (fun (f, t) -> print (Printf.sprintf "symref %s %s\n" f t)) c.symref
        end;
        first := false;
        (match fields " \t\n\r" line with
         | h :: name :: _ ->
             if Proto.find_sub name "^{}" 0 = None then begin
               if not (name = "HEAD" || (String.starts_with ~prefix:"refs/" name && Proto.okref name)) then
                 error "remote side sent invalid ref: %s" name;
               let skip =
                 match o.branch with
                 | Some b -> not (branchmatch name b)
                 | None -> name <> "HEAD" && not (String.starts_with ~prefix:"refs/heads/" name) && not (String.starts_with ~prefix:"refs/tags/" name) in
               if not skip then begin
                 let want = match hparse h with Some w -> w | None -> error "invalid hash %s" h in
                 let have = Option.value (resolveremote st o.upstream name) ~default:Hash.zero in
                 refs := (name, want, have) :: !refs
               end
             end
         | _ -> error "invalid ref line");
        advert ()
  in
  advert ();
  let refs = List.rev !refs in
  let showrefs () =
    List.iter (fun (name, want, have) -> print (Printf.sprintf "remote %s %s local %s\n" name (Hash.to_hex want) (Hash.to_hex have))) refs in
  if o.listonly then (Proto.flush c; showrefs ())
  else begin
    (* the wants, the capabilities on the first *)
    let caps = ref ((if c.multiack then " multi_ack" else "") ^ (if c.sideband64k then " side-band-64k" else if c.sideband then " side-band" else "")) in
    let req = ref false in
    List.iteri (fun i (_, want, have) ->
      let dup = List.exists (fun (_, w, _) -> Hash.compare w want = 0) (List.filteri (fun j _ -> j < i) refs) in
      if Hash.compare have want <> 0 && not dup && not (Store.mem st want) then begin
        Proto.write_pkt c (Printf.sprintf "want %s%s\n" (Hash.to_hex want) !caps);
        caps := "";
        req := true
      end) refs;
    Proto.flush c;
    (* the haves: our copies, the -h heads, then their ancestors *)
    let nsent = ref 0 and had = Hashtbl.create 64 and q = Query.heap () in
    let send_have h =
      (match Store.read st h with
       | Commit cm -> List.iter (Query.put_commit st q) cm.parents
       | _ -> ()
       | exception Store.Missing _ -> error "missing exected object: %s" (Hash.to_hex h));
      Proto.write_pkt c ("have " ^ Hash.to_hex h);
      Hashtbl.replace had h ();
      incr nsent in
    List.iter (fun (_, _, have) -> if Hash.compare have Hash.zero <> 0 && not (Hashtbl.mem had have) then send_have have) refs;
    List.iter send_have o.heads;
    let rec more () =
      if !req && !nsent < 256 then
        match Query.pop_commit q with
        | Some h -> if not (Hashtbl.mem had h) then send_have h; more ()
        | None -> () in
    more ();
    if not !req then Proto.flush c;
    Proto.write_pkt c "done\n";
    if not !req then showrefs ()
    else begin
      eprint "fetching...  ";
      if c.multiack then begin
        let rec acks i =
          if i < !nsent then
            match Proto.read_pkt c with
            | Pkt buf when String.starts_with ~prefix:"NAK\n" buf -> ()
            | Pkt buf when String.starts_with ~prefix:"ACK " buf -> if List.length (fields " \t" buf) = 2 then () else acks (i + 1)
            | Pkt buf -> error "bad response: '%s'" buf
            | Flush -> error "bad response: ''" in
        acks 0
      end;
      ignore (Proto.read_pkt c);
      let b = Buffer.create 65536 in
      if not c.sideband && not c.sideband64k && not c.multiack then begin
        (* torvalds git sends duplicate have lines at times: skip to
         * PACK *)
        let rec skip () =
          let h = Proto.read_raw c 4 in
          if String.length h <> 4 then error "fetch packfile: short read";
          if h <> "PACK" then begin
            let l = match int_of_string_opt ("0x" ^ h) with Some l -> l | None -> error "fetch packfile: junk pktline" in
            if String.length (Proto.read_raw c (l - 4)) <> l - 4 then error "fetch packfile: short read";
            skip ()
          end in
        skip ();
        Buffer.add_string b "PACK"
      end;
      let rec data () =
        if not c.sideband && not c.sideband64k then begin
          let s = Proto.read_raw c 65536 in
          if s <> "" then (Buffer.add_string b s; data ())
        end
        else
          match Proto.read_pkt c with
          | Flush -> ()
          | Pkt p ->
              (match p.[0] with
               | '\001' when String.length p > 1 -> Buffer.add_string b (String.sub p 1 (String.length p - 1))
               | '\001' | '\002' -> ()
               | '\003' -> eprint (Printf.sprintf "error: %s\n" (String.sub p 1 (String.length p - 1)))
               | ch -> eprint (Printf.sprintf "unknown sideband(%c:%d) data: %s\n" ch (Char.code ch) (String.sub p 1 (String.length p - 1))));
              data () in
      data ();
      eprint "\n";
      let pack = Buffer.contents b in
      (try ignore (Store.add_pack st ~warn:eprint pack)
       with Object.Corrupt m -> error "corrupt packfile: %s" m);
      showrefs ()
    end
  end
