(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Usbdwc.mli *)

open Types
open Usb

external usb_transfer : int -> int -> int -> int = "usb_transfer"
external usb_buffer : unit -> int = "usb_buffer"
external usb_pid : unit -> int = "usb_pid"

let hcitype = "dwcotg"

(* each transfer printed (debugging) *)
let debug = ref false

let estalled = "endpoint stalled"
let enotconf = "endpoint not configured"
let ebadlen = "bad usb request length"
let eio = "i/o error"

(* the PIDs: DATA0, DATA1, SETUP (HCTSIZ's bits 29-30) *)
let data0 = 0 and data1 = 2 and setup = 3

(* the registers: the controller at the peripherals' 0x980000 *)
let reg off = 0x980000 + off
let get off = Machine.io_get16 (reg off) false lor (Machine.io_get16 (reg off) true lsl 16)
let set off v = Machine.io_set32 (reg off) (v lsr 16) (v land 0xffff)

let gahbcfg = 0x008 and hprt = 0x440
let dmaenable = 1 lsl 5

(* hport0's bits *)
let prtconnsts = 1 and prtconndet = 2 and prtena = 4 and prtenchng = 8 and prtovrcurract = 0x10
and prtovrcurrchng = 0x20 and prtsusp = 0x80 and prtrst = 0x100 and prtpwr = 0x1000
let prtspd v = (v lsr 17) land 3

(* the replies' HP bits *)
let hppresent = 1 and hpenable = 2 and hpsuspend = 4 and hpovercurrent = 8 and hpreset = 0x10
and hppower = 0x100 and hpslow = 0x200 and hphigh = 0x400 and hpstatuschg = 0x10000 and hpchange = 0x20000

let init () =
  set gahbcfg (get gahbcfg lor dmaenable);
  set hprt (prtpwr lor prtconndet lor prtenchng lor prtovrcurrchng)

(*****************************************************************************)
(* The root port *)
(*****************************************************************************)

let enabledelay = 50
let resetdelayhs = 50

let portenable _ on =
  if not on then set hprt (prtpwr lor prtena);
  Proc.tsleep enabledelay;
  0

(* the W1C bits a read found, acknowledged *)
let ack s =
  let b = s land (prtconndet lor prtenchng lor prtovrcurrchng) in
  if b <> 0 then set hprt (prtpwr lor b)

let portreset _ on =
  if on then begin
    set hprt (prtpwr lor prtrst);
    Proc.tsleep resetdelayhs;
    set hprt prtpwr;
    Proc.tsleep enabledelay;
    let s = get hprt in
    ack s;
    if s land prtena = 0 then Devcons.print "usbotg: host port not enabled after reset"
  end;
  0

let portstatus _ =
  let s = get hprt in
  ack s;
  let bit m r = if s land m <> 0 then r else 0 in
  bit prtconnsts hppresent lor bit prtconndet hpstatuschg lor bit prtena hpenable lor bit prtenchng hpchange
  lor bit prtovrcurract hpovercurrent lor bit prtsusp hpsuspend lor bit prtrst hpreset lor bit prtpwr hppower
  lor (match prtspd s with 0 -> hphigh | 2 -> hpslow | _ -> 0)

(*****************************************************************************)
(* Transfers *)
(*****************************************************************************)

let page = 4096

(* the channel's description (usb.c's): the device's address (0 until
 * set), the endpoint, its type, the direction, low speed, the maximum
 * packet (chansetup) *)
let desc ep input =
  let addr = match ep.dev.state with Dconfig | Dreset -> 0 | _ -> ep.dev.dnb in
  let tt = match ep.ttype with Tiso -> 1 | Tbulk -> 2 | Tintr -> 3 | _ -> 0 in
  addr lor (ep.enb lsl 7) lor (tt lsl 11) lor ((if input then 1 else 0) lsl 13)
  lor ((if ep.dev.speed = Lowspeed then 1 else 0) lsl 14) lor (ep.maxpkt lsl 16)

let round n a = ((n + a - 1) / a) * a

(* chanio: [len] bytes in, or [data] out, starting with [pid]: the bytes
 * (in), how many moved, the next PID. A NAK waited on (an interrupt
 * endpoint's polling interval, else 1ms) and tried again, in a loop (a
 * hub's endpoint NAKs until a port changes: a recursion there grew the
 * kernel stack at each NAK), a STALL raised *)
let chanio ep input pid data len =
  let buf = usb_buffer () in
  let len = if input then min len page else String.length data in
  let xlen = if input then min page (round (max len 1) ep.maxpkt) else len in
  let result = ref None in
  while !result = None do
    if not input && len > 0 then Machine.Phys.write buf data;
    let n = usb_transfer (desc ep input) pid (if input && len = 0 then 0 else xlen) in
    if !debug then Devcons.print (Printf.sprintf "{ep%d.%d %s %s len %d xlen %d pid %d -> %d}\n" ep.dev.dnb ep.enb
                                    (match ep.ttype with Tctl -> "ctl" | Tintr -> "intr" | Tbulk -> "bulk" | _ -> "?")
                                    (if input then "in" else "out") len xlen pid n);
    if n >= 0 then begin
      let n = min n len in
      result := Some ((if input then Machine.Phys.read buf n else ""), n, usb_pid ())
    end
    else if n = -1 then Proc.tsleep (if ep.ttype = Tintr then max 1 ep.pollival else 1)
    else if n = -2 then raise (Error estalled)
    else begin
      Devcons.print (Printf.sprintf "usbotg: ep%d.%d error\n" ep.dev.dnb ep.enb);
      raise (Error eio)
    end
  done;
  match !result with Some r -> r | None -> raise (Error eio)

(* multitrans: a read a packet at a time, to a short one *)
let multitrans ep n =
  let b = Buffer.create n in
  let rec go () =
    let m = min ep.maxpkt (n - Buffer.length b) in
    let s, k, pid = chanio ep true ep.toggle.(0) "" m in
    ep.toggle.(0) <- pid;
    Buffer.add_string b s;
    if Buffer.length b < n && k = ep.maxpkt then go () in
  go ();
  Buffer.contents b

(* eptrans: an interrupt or bulk transfer (a STALL: nothing moved) *)
let eptrans ep write data n =
  if ep.clrhalt then begin
    ep.clrhalt <- false;
    if ep.mode <> 0 then ep.toggle.(1) <- data0;
    if ep.mode <> 1 then ep.toggle.(0) <- data0
  end;
  let rw = if write then 1 else 0 in
  try
    if not write && ep.ttype = Tbulk then let s = multitrans ep n in s, String.length s
    else begin
      let s, k, pid = chanio ep (not write) ep.toggle.(rw) data n in
      ep.toggle.(rw) <- pid;
      s, k
    end
  with Error e when e = estalled -> "", 0

let get2 s o = Char.code s.[o] lor (Char.code s.[o + 1] lsl 8)

(* ctltrans: a control transfer, its setup packet and data as written:
 * SETUP, the data (DATA1 on), the status the other way; an IN's data
 * kept for the reads (ctldata) *)
let ctltrans ep req =
  ep.cb <- None;
  let n = String.length req in
  if n < rsetuplen then raise (Error ebadlen);
  let input = Char.code req.[0] land rd2h <> 0 in
  let datalen = if input then get2 req 6 else n - rsetuplen in
  if input && (datalen <= 0 || datalen > 32 * 1024) then raise (Error ebadlen);
  try
    ignore (chanio ep false setup (String.sub req 0 rsetuplen) 0);
    if input then begin
      let data =
        if ep.dev.hub <= 1 then begin ep.toggle.(0) <- data1; multitrans ep datalen end
        else let s, _, _ = chanio ep true data1 "" datalen in s in
      ep.cb <- Some data;
      ignore (chanio ep false data1 "" 0);
      rsetuplen
    end else begin
      if datalen > 0 then ignore (chanio ep false data1 (String.sub req rsetuplen datalen) 0);
      ignore (chanio ep true data1 "" 0);
      rsetuplen + datalen
    end
  with Error e when e = estalled -> 0

let ctldata ep n =
  match ep.cb with
  | None -> ""
  | Some b ->
      let k = min n (String.length b) in
      ep.cb <- (if k = String.length b then None else Some (String.sub b k (String.length b - k)));
      String.sub b 0 k

let epopen ep = if ep.ttype = Tnone then raise (Error enotconf)
let epclose ep = ep.cb <- None

let now_ms () = !Proc.ticks * 10

(* an interrupt endpoint polled no sooner than its interval *)
let pollwait ep =
  let elapsed = now_ms () - ep.lastpoll in
  if elapsed < ep.pollival then Proc.tsleep (ep.pollival - elapsed)

let epread ep n =
  match ep.ttype with
  | Tctl -> ctldata ep n
  | Tintr | Tbulk ->
      if ep.ttype = Tintr then pollwait ep;
      let s, _ = eptrans ep false "" n in
      ep.lastpoll <- now_ms ();
      s
  | _ -> raise (Error egreg)

let epwrite ep data =
  match ep.ttype with
  | Tctl -> ctltrans ep data
  | Tintr | Tbulk ->
      if ep.ttype = Tintr then pollwait ep;
      let _, k = eptrans ep true data (String.length data) in
      ep.lastpoll <- now_ms ();
      k
  | _ -> raise (Error egreg)
