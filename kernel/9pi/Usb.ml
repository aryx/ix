(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Usb.mli *)

(* a transfer type (Tnone: not configured yet) *)
type ttype = Tnone | Tctl | Tiso | Tbulk | Tintr

type speed = Fullspeed | Lowspeed | Highspeed | Nospeed

(* a device's state: its address not set yet, set, gone, its port being
 * reset *)
type dstate = Dconfig | Denabled | Ddetach | Dreset

(* a device (Udev): its number (its USB address once set), whether a hub
 * or the root hub, its speed, its parent hub's number and port there,
 * its endpoints by number *)
type udev = {
  dnb : int;
  mutable state : dstate;
  mutable ishub : bool;
  isroot : bool;
  mutable speed : speed;
  mutable hub : int;
  mutable port : int;
  deps : ep option array;
}

(* an endpoint (Ep): its index (its files' qids), its number in the
 * device, the device, its device's endpoint 0 (None: itself); how many
 * hold it; its name at #u, open or not, its mode (OREAD 0, OWRITE 1,
 * ORDWR 2), a halt cleared, its info for humans, its maximum packet, its
 * type, its load (µs), the root hub's reply (-1: none), its data
 * toggles (read, write: a PID, 0 DATA0 or 2 DATA1), its polling interval
 * (ms), iso's rate and sample size, its Tds a µframe, its timeout; a
 * control transfer's reply not read yet, its last poll (ms) *)
and ep = {
  idx : int;
  enb : int;
  dev : udev;
  mutable ep0 : ep option;
  mutable eref : int;
  mutable ename : string;
  mutable inuse : bool;
  mutable mode : int;
  mutable clrhalt : bool;
  mutable info : string;
  mutable maxpkt : int;
  mutable ttype : ttype;
  mutable load : int;
  mutable rhrepl : int;
  toggle : int array;
  mutable pollival : int;
  mutable hz : int;
  mutable samplesz : int;
  mutable ntds : int;
  mutable tmout : int;
  mutable cb : string option;
  mutable lastpoll : int;
}

let ep0 ep = match ep.ep0 with Some e -> e | None -> ep

let rsetuplen = 8
let rd2h = 0x80
