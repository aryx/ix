(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The USB host controller's driver (principia's usbdwc.c): the
 * Synopsys DWC2 of the BCM2835, an endpoint's transfers and the root
 * port. A transfer is kernel/lib's usb.c's: one host channel, the data
 * through its DMA page, polled to its end (9pi's waits for the FIQ's
 * wakeup); a NAK tried again after a sleep (an interrupt endpoint's
 * polling interval), a STALL the endpoint's "endpoint stalled"; the data
 * toggles kept in the endpoint (usb.c's usb_pid). Split transactions are
 * skipped, as 9pi's are under emulation (QEMU's dwc2 routes a packet by
 * its address alone). *)

open Usb

(* the controller started (init: DMA, the root port powered) *)
val init : unit -> unit

(* the root port's (hub replies to usbd, devusb's root hub): enable,
 * reset, status (HP bits) *)
val portenable : int -> bool -> int
val portreset : int -> bool -> int
val portstatus : int -> int

(* an endpoint opened, closed; read (n bytes at most), written (the
 * bytes taken) *)
val epopen : ep -> unit
val epclose : ep -> unit
val epread : ep -> int -> string
val epwrite : ep -> string -> int

(* each transfer printed on the console (debugging) *)
val debug : bool ref

(* the controller's type ("dwcotg"), what reset prints *)
val hcitype : string
