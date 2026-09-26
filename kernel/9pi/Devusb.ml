(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devusb.mli *)

open Types
open Usb

let edetach = "device is detached"
let enotconf = "endpoint not configured"
let eio = "i/o error"

(* the qids: #u 0, #u/usb 1, #u/usb/ctl 2, then 4 per endpoint i: its
 * directory 3+4i, data 4+4i, ctl 5+4i *)
let qdir = 0 and qusbdir = 1 and qctl = 2 and qep0dir = 3
let qepdir = 0 and qepio = 1 and qepctl = 2

let neps = 128
let ndeveps = 16
let xfertmout = 2000

let eps : ep option array = Array.make neps None
let epmax = ref 0
let usbidgen = ref 0

let qid2epidx q =
  let i = (q - qep0dir) / 4 in
  if q < qep0dir || i >= !epmax then -1 else match eps.(i) with Some _ -> i | None -> -1

let isqtype q t = q >= qep0dir && (q - qep0dir) land 3 = t

let the q = let i = qid2epidx q in if i < 0 then raise (Error eio) else match eps.(i) with Some e -> e | None -> raise (Error eio)

(* one holder less (the last: the endpoint gone, and its hold on its
 * endpoint 0) *)
let rec putep ep =
  ep.eref <- ep.eref - 1;
  if ep.eref = 0 then begin
    eps.(ep.idx) <- None;
    if ep.idx = !epmax - 1 then decr epmax;
    if ep.ep0 = None && ep.dev.dnb = !usbidgen then decr usbidgen;
    ep.dev.deps.(ep.enb) <- None;
    match ep.ep0 with Some e0 -> ep.ep0 <- None; putep e0 | None -> ()
  end

let epalloc dev nb =
  let rec free i = if i = neps then raise (Error "usb: bug: too few endpoints") else match eps.(i) with None -> i | Some _ -> free (i + 1) in
  let i = free 0 in
  let ep = { idx = i; enb = nb; dev = dev; ep0 = None; eref = 1; ename = ""; inuse = false; mode = 2; clrhalt = false;
             info = ""; maxpkt = 8; ttype = Tnone; load = 0; rhrepl = -1; toggle = [| 0; 0 |]; pollival = 0; hz = 0;
             samplesz = 0; ntds = 1; tmout = 0; cb = None; lastpoll = 0 } in
  if !epmax <= i then epmax := i + 1;
  eps.(i) <- Some ep;
  ep

(* newdev: a device's endpoint 0 (the controller high speed) *)
let newdev ishub isroot =
  incr usbidgen;
  if !usbidgen >= 0x7f then Devcons.print "#u: too many device addresses; reuse them more\n";
  let d = { dnb = !usbidgen; state = Dconfig; ishub = ishub; isroot = isroot; speed = Highspeed; hub = 0; port = 0;
            deps = Array.make ndeveps None } in
  let ep = epalloc d 0 in
  d.deps.(0) <- Some ep;
  ep.ttype <- Tctl;
  ep.tmout <- xfertmout;
  ep

(* newdevep: another endpoint of ep's device *)
let newdevep ep nb tt mode =
  let d = ep.dev in
  if d.deps.(nb) <> None then raise (Error "endpoint already in use");
  let nep = epalloc d nb in
  ep.eref <- ep.eref + 1;
  d.deps.(nb) <- Some nep;
  nep.ep0 <- Some ep;
  nep.mode <- mode;
  nep.ttype <- tt;
  match tt with
  | Tctl -> nep.tmout <- xfertmout
  | Tintr -> nep.pollival <- 10
  | Tiso -> nep.tmout <- xfertmout; nep.pollival <- 10; nep.samplesz <- 4; nep.hz <- 44100
  | _ -> ()

(*****************************************************************************)
(* Names *)
(*****************************************************************************)

let ttname = function Tnone -> "none" | Tctl -> "control" | Tiso -> "iso" | Tintr -> "interrupt" | Tbulk -> "bulk"
let spname = function Fullspeed -> "full" | Lowspeed -> "low" | Highspeed -> "high" | Nospeed -> "no"
let modename m = match m with 0 -> "r" | 1 -> "w" | _ -> "rw"
let dsname = function Dconfig -> "config" | Denabled -> "enabled" | Ddetach -> "detached" | Dreset -> "reset"

let name2speed = function "full" -> Fullspeed | "low" -> Lowspeed | "high" -> Highspeed | _ -> Nospeed

let name2ttype s =
  match s with
  | "none" -> Tnone | "control" -> Tctl | "iso" -> Tiso | "interrupt" -> Tintr | "bulk" -> Tbulk
  | _ ->
      (* a standard endpoint type's number: 0 control, 1 iso, 2 bulk, 3 interrupt *)
      (match (try int_of_string s with Failure _ -> -1) with 0 -> Tctl | 1 -> Tiso | 2 -> Tbulk | 3 -> Tintr | _ -> Tnone)

let name2mode = function "r" -> 0 | "w" -> 1 | "rw" -> 2 | _ -> -1

(* seprintep, not all *)
let seprintep ep =
  Printf.sprintf "%s %s %s speed %s maxpkt %d pollival %d samplesz %d hz %d hub %d port %d %s%s"
    (dsname ep.dev.state) (ttname ep.ttype) (modename ep.mode) (spname ep.dev.speed) ep.maxpkt ep.pollival
    ep.samplesz ep.hz ep.dev.hub ep.dev.port (if ep.inuse then "busy" else "idle")
    (if ep.info <> "" then "\n" ^ ep.info ^ " " ^ Usbdwc.hcitype ^ "\n" else "\n")

let epname ep = Printf.sprintf "ep%d.%d" ep.dev.dnb ep.enb

(*****************************************************************************)
(* The tree (usbgen) *)
(*****************************************************************************)

let dirq p = { path = p; vers = 0; typ = Qt_dir }
let fileq p = { path = p; vers = 0; typ = Qt_file }

let dmexcl = 1 lsl 29
let epdataperm mode = dmexcl lor (match mode with 0 -> 0o440 | 1 -> 0o220 | _ -> 0o660)

let indexed () = let l = ref [] in for i = !epmax - 1 downto 0 do match eps.(i) with Some e -> l := (i, e) :: !l | None -> () done; !l

(* a directory's entries, by its qid path *)
let entries (c : chan) q =
  if q = qdir then
    Dev.mkdir c "usb" (dirq qusbdir) 0 0o555
    :: List.fold_right (fun (i, ep) acc ->
         if ep.ename <> "" then Dev.mkdir c ep.ename (fileq (qep0dir + qepio + (4 * i))) 0 (epdataperm ep.mode) :: acc
         else acc) (indexed ()) []
  else if q = qusbdir then
    Dev.mkdir c "ctl" (fileq qctl) 0 0o666
    :: List.map (fun (i, ep) -> Dev.mkdir c (epname ep) (dirq (qep0dir + (4 * i))) 0 0o755) (indexed ())
  else if isqtype q qepdir then begin
    let ep = the q in
    [ Dev.mkdir c "data" (fileq (q + qepio)) 0 (epdataperm ep.mode); Dev.mkdir c "ctl" (fileq (q + qepctl)) 0 0o664 ]
  end
  else raise (Error enotdir)

(* the directory a file is listed in *)
let container q = if q = qusbdir then qdir else if q = qctl || isqtype q qepdir then qusbdir else q - ((q - qep0dir) land 3)

let stat (c : chan) =
  let q = c.qid.path in
  if q = qdir then Dev.mkdir c "#u" c.qid 0 0o555
  else
    try List.find (fun d -> d.d_qid.path = q) (entries c (container q))
    with Not_found -> raise (Error enonexist)

(*****************************************************************************)
(* The root hub (rhubread, rhubwrite) *)
(*****************************************************************************)

let get2 s o = Char.code s.[o] lor (Char.code s.[o + 1] lsl 8)

let rgetstatus = 0 and rsetfeature = 3
let rportenable = 1 and rportreset = 4

let rhubread ep n =
  if not ep.dev.isroot || ep.enb <> 0 || n < 2 || ep.rhrepl < 0 then None
  else begin
    let r = ep.rhrepl in
    ep.rhrepl <- -1;
    let s = String.make n '\000' in
    String.set s 0 (Char.chr (r land 0xff));
    String.set s 1 (Char.chr ((r lsr 8) land 0xff));
    Some s
  end

let rhubwrite ep s =
  if not ep.dev.isroot || ep.enb <> 0 then None
  else begin
    let n = String.length s in
    if n <> rsetuplen then raise (Error "root hub is a toy hub");
    ep.rhrepl <- -1;
    (* Rh2d or Rd2h, Rclass, Rother *)
    let typ = Char.code s.[0] in
    if typ <> 0x23 && typ <> 0xa3 then raise (Error "root hub is a toy hub");
    let cmd = Char.code s.[1] and feature = get2 s 2 and port = get2 s 4 in
    if port < 1 || port > 1 then raise (Error "bad hub port number");
    ep.rhrepl <-
      (if feature = rportenable then Usbdwc.portenable port (cmd = rsetfeature)
       else if feature = rportreset then Usbdwc.portreset port (cmd = rsetfeature)
       else if feature = rgetstatus then Usbdwc.portstatus port
       else 0);
    Some n
  end

(*****************************************************************************)
(* Control messages (epctl, usbctl) *)
(*****************************************************************************)

(* the name of a device made by "newdev", read back on the same
 * channel (c->aux) *)
let pending : (chan * string) list ref = ref []

let words s = List.filter (fun w -> w <> "") (String.split_on_char ' ' (String.map (fun c -> if c = '\n' || c = '\t' then ' ' else c) s))

let num s = try int_of_string s with Failure _ -> 0

let epctl ep (c : chan) s =
  let d = ep.dev in
  let e0 = ep0 ep in
  let f = words s in
  let cmd = match f with x :: _ -> x | [] -> raise (Error ebadctl) in
  let nargs = List.length f in
  let arg i = List.nth f i in
  let need n = if nargs <> n then raise (Error "wrong #args in control message") in
  if List.mem cmd [ "new"; "speed"; "hub"; "reset" ] && ep != e0 then raise (Error "allowed only on a setup endpoint");
  if not (List.mem cmd [ "clrhalt"; "detach"; "debug"; "name" ]) && ep != e0 && ep.inuse then
    raise (Error "must configure before using");
  (match cmd with
   | "new" ->
       need 4;
       let nb = num (arg 1) in
       if nb < 0 || nb >= ndeveps then raise (Error "bad endpoint number");
       let tt = name2ttype (arg 2) in
       if tt = Tnone then raise (Error "unknown endpoint type");
       let mode = name2mode (arg 3) in
       if mode < 0 then raise (Error "unknown i/o mode");
       newdevep ep nb tt mode
   | "newdev" ->
       need 3;
       if ep != e0 || not d.ishub then raise (Error "not a hub setup endpoint");
       let sp = name2speed (arg 1) in
       if sp = Nospeed then raise (Error "speed must be full|low|high");
       let nep = newdev false false in
       nep.dev.speed <- sp;
       if sp <> Lowspeed then nep.maxpkt <- 64;
       nep.dev.hub <- d.dnb;
       nep.dev.port <- num (arg 2);
       pending := (c, epname nep) :: List.filter (fun (x, _) -> x != c) !pending
   | "hub" -> need 1; d.ishub <- true
   | "speed" ->
       need 2;
       let sp = name2speed (arg 1) in
       if sp = Nospeed then raise (Error "speed must be full|low|high");
       d.speed <- sp
   | "maxpkt" ->
       need 2;
       let l = num (arg 1) in
       if l < 1 || l > 1024 then raise (Error "maxpkt not in [1:1024]");
       ep.maxpkt <- l
   | "ntds" ->
       need 2;
       let l = num (arg 1) in
       if l < 1 || l > 3 then raise (Error "ntds not in [1:3]");
       ep.ntds <- l
   | "pollival" ->
       need 2;
       if ep.ttype <> Tintr && ep.ttype <> Tiso then raise (Error "not an intr or iso endpoint");
       let l = num (arg 1) in
       if ep.ttype = Tiso || d.speed = Highspeed then begin
         if l < 1 || l > 16 then raise (Error "pollival power not in [1:16]");
         ep.pollival <- 1 lsl (l - 1)
       end else begin
         if l < 1 || l > 255 then raise (Error "pollival not in [1:255]");
         ep.pollival <- l
       end
   | "samplesz" | "hz" -> raise (Error "not an iso endpoint")
   | "clrhalt" -> need 1; ep.clrhalt <- true
   | "info" ->
       if String.length s < 7 || String.sub s 0 5 <> "info " then raise (Error ebadctl);
       let b = String.sub s 5 (min 1019 (String.length s - 5)) in
       ep.info <- (if b <> "" && b.[String.length b - 1] = '\n' then String.sub b 0 (String.length b - 1) else b)
   | "address" -> need 1; d.state <- Denabled
   | "detach" ->
       need 1;
       if d.isroot then raise (Error "can't detach a root hub");
       d.state <- Ddetach;
       Array.iter (fun o -> match o with Some e -> putep e | None -> ()) d.deps
   | "debug" -> need 2
   | "name" -> need 2; ep.ename <- arg 1
   | "timeout" ->
       need 2;
       if ep.ttype = Tiso || ep.ttype = Tctl then raise (Error "ctl ignored for this endpoint type");
       ep.tmout <- num (arg 1);
       if ep.tmout <> 0 && ep.tmout < xfertmout then ep.tmout <- xfertmout
   | "reset" ->
       need 1;
       if ep.ttype <> Tctl then raise (Error "not a control endpoint");
       if d.state <> Denabled then raise (Error "forbidden on devices not enabled");
       d.state <- Dreset
   | _ -> raise (Error ebadctl));
  String.length s

(*****************************************************************************)
(* The device *)
(*****************************************************************************)

let usbload speed maxpkt =
  let bs = 10 * maxpkt in
  (match speed with
   | Highspeed -> (55 * 8 * 2) + (2 * (3 + bs)) + 1000
   | Fullspeed -> 9107 + (84 * (4 + bs)) + 1000
   | Lowspeed -> 64107 + (2 * 333) + (667 * (3 + bs)) + 1000
   | Nospeed -> 0) / 1000

let readstr off n s = if off >= String.length s then "" else String.sub s off (min n (String.length s - off))

let ctlread (c : chan) n off =
  let q = c.qid.path in
  let s =
    if q = qctl then String.concat "" (List.map (fun (_, ep) -> epname ep ^ " " ^ seprintep ep) (indexed ()))
    else begin
      let ep = the q in
      try let name = List.assq c !pending in pending := List.filter (fun (x, _) -> x != c) !pending; name
      with Not_found -> seprintep ep
    end in
  readstr off n s

let init () =
  (* hciprobe, usbinit: the controller, its root hub *)
  Usbdwc.init ();
  Devcons.print (Printf.sprintf "#u/usb/ep1.0: %s: port 0X0 irq 9\n" Usbdwc.hcitype);
  let root = newdev true true in
  root.dev.state <- Denabled;
  root.maxpkt <- 64;
  root.info <- "ports 1";
  let d = Dev.default 'u' "usb" in
  Dev.register { d with
    Dev.attach = (fun _ -> Dev.attach 'u' 0 (dirq qdir));
    Dev.walk = (fun c _ name ->
      let q = c.qid.path in
      if c.qid.typ <> Qt_dir then raise (Error enotdir)
      else if name = ".." then (if q <= qusbdir then dirq qdir else dirq qusbdir)
      else try (List.find (fun d -> d.d_name = name) (entries c q)).d_qid with Not_found -> raise (Error enonexist));
    Dev.stat = stat;
    Dev.dirs = (fun c -> entries c c.qid.path);
    Dev.open_ = (fun c m ->
      let q = c.qid.path in
      if q >= qep0dir && qid2epidx q < 0 then raise (Error eio);
      if q < qep0dir || isqtype q qepctl || isqtype q qepdir then Dev.tab_open c m
      else begin
        let ep = the q in
        if ep.inuse then raise (Error einuse);
        let mode = match m.access with Oread | Oexec -> 0 | Owrite -> 1 | Ordwr -> 2 in
        if mode <> 0 && ep.mode = 0 then raise (Error eperm);
        if mode <> 1 && ep.mode = 1 then raise (Error eperm);
        if ep.ttype = Tnone then raise (Error enotconf);
        ep.clrhalt <- false;
        ep.rhrepl <- -1;
        if ep.load = 0 then ep.load <- usbload ep.dev.speed ep.maxpkt;
        Usbdwc.epopen ep;
        ep.inuse <- true;
        (* a hold for the open file *)
        ep.eref <- ep.eref + 1;
        c
      end);
    Dev.close = (fun c ->
      let q = c.qid.path in
      pending := List.filter (fun (x, _) -> x != c) !pending;
      if not (q < qep0dir || isqtype q qepctl || isqtype q qepdir) then
        let i = qid2epidx q in
        match (if i < 0 then None else eps.(i)) with
        | Some ep ->
            if ep.inuse then begin Usbdwc.epclose ep; ep.inuse <- false end;
            putep ep
        | None -> ());
    Dev.read = (fun c n off ->
      let q = c.qid.path in
      if q = qctl || isqtype q qepctl then ctlread c n off
      else begin
        let ep = the q in
        if ep.dev.state = Ddetach then raise (Error edetach);
        if ep.mode = 1 || not ep.inuse then raise (Error ebadusefd);
        match ep.ttype with
        | Tnone -> raise (Error enotconf)
        | Tctl -> (match rhubread ep n with Some s -> s | None -> Usbdwc.epread ep n)
        | _ -> Usbdwc.epread ep n
      end);
    Dev.write = (fun c s _ ->
      let q = c.qid.path in
      if c.qid.typ = Qt_dir then raise (Error eisdir);
      if q = qctl then begin
        (match words s with
         | [ "debug"; _ ] | [ "dump" ] -> ()
         | _ -> raise (Error "unknown control message"));
        String.length s
      end
      else if isqtype q qepctl then begin
        let ep = the q in
        if ep.dev.state = Ddetach then raise (Error edetach);
        if List.exists (fun (x, _) -> x == c) !pending then begin
          pending := List.filter (fun (x, _) -> x != c) !pending;
          raise (Error "read, not write, expected")
        end;
        epctl ep c s
      end else begin
        let ep = the q in
        if ep.dev.state = Ddetach then raise (Error edetach);
        if ep.mode = 0 || not ep.inuse then raise (Error ebadusefd);
        match ep.ttype with
        | Tnone -> raise (Error enotconf)
        | Tctl -> (match rhubwrite ep s with Some n -> n | None -> ignore (Usbdwc.epwrite ep s); String.length s)
        | _ -> ignore (Usbdwc.epwrite ep s); String.length s
      end);
  }
