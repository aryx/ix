(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Usbhost.mli *)

module Phys = Machine.Phys

external usb_init : unit -> bool = "usb_init"
external usb_transfer : int -> int -> int -> int = "usb_transfer"
external usb_buffer : unit -> int = "usb_buffer"

(*****************************************************************************)
(* Transfers *)
(*****************************************************************************)

type ttype = Control | Interrupt

type result = Bytes_moved of int | Nak | Stall | Failed

(* one transfer (usb.c's): the DMA page's first [len] bytes *)
let transfer addr ep ttype input mps pid len =
  let desc = addr lor (ep lsl 7) lor ((match ttype with Control -> 0 | Interrupt -> 3) lsl 11)
             lor ((if input then 1 else 0) lsl 13) lor (mps lsl 16) in
  let n = usb_transfer desc pid len in
  if n >= 0 then Bytes_moved n else if n = -1 then Nak else if n = -2 then Stall else Failed

let data0 = 0 and data1 = 2 and setup_pid = 3

(* a control transfer: SETUP's 8 bytes, [length] bytes IN (or none),
 * the status stage the other way; its data, or None. A NAK tried again *)
let control addr mps req value index length =
  let le16 v = String.make 1 (Char.chr (v land 0xff)) ^ String.make 1 (Char.chr ((v lsr 8) land 0xff)) in
  (* on the wire bmRequestType first, then bRequest *)
  let packet = String.make 1 (Char.chr (req lsr 8)) ^ String.make 1 (Char.chr (req land 0xff)) ^ le16 value ^ le16 index ^ le16 length in
  let rec again k f = match f () with Nak when k > 0 -> again (k - 1) f | r -> r in
  let buf = usb_buffer () in
  Phys.write buf packet;
  match again 100 (fun () -> transfer addr 0 Control false mps setup_pid 8) with
  | Bytes_moved _ ->
      let input = req land 0x8000 <> 0 in
      let data =
        if length = 0 then Some ""
        else match again 100 (fun () -> transfer addr 0 Control input mps data1 length) with
          | Bytes_moved n -> Some (Phys.read buf n)
          | _ -> None in
      (match data with
       | None -> None
       | Some d ->
           match again 100 (fun () -> transfer addr 0 Control (not input || length = 0) mps data1 0) with
           | Bytes_moved _ -> Some d
           | _ -> None)
  | _ -> None

(* the standard requests used, by bmRequestType << 8 | bRequest *)
let get_descriptor = 0x8006 and set_address = 0x0005 and set_configuration = 0x0009

let byte s i = Char.code s.[i]
let word s i = byte s i lor (byte s (i + 1) lsl 8)

(*****************************************************************************)
(* The devices *)
(*****************************************************************************)

type kind = Keyboard | Mouse

(* a HID device found: its address, its interrupt endpoint and packet,
 * the endpoint's data toggle, its last report *)
type device = { addr : int; ep : int; mps : int; kind : kind; mutable toggle : int; mutable last : string }

let devices : device list ref = ref []
let next_addr = ref 2                   (* 1: the hub *)

(* a device on a hub's port, at address 0 once the port is reset: its
 * boot HID interface found in its configuration (class 3, subclass 1,
 * protocol 1 a keyboard, 2 a mouse; its IN interrupt endpoint); given an
 * address, configured, in the boot protocol, reports only on change *)
let hid_device () =
  match control 0 8 get_descriptor 0x100 0 8 with
  | None -> ()
  | Some d ->
      let mps0 = byte d 7 in
      let addr = !next_addr in
      incr next_addr;
      match control 0 mps0 set_address addr 0 0 with
      | None -> ()
      | Some _ ->
          match control addr mps0 get_descriptor 0x200 0 9 with
          | None -> ()
          | Some c ->
              match control addr mps0 get_descriptor 0x200 0 (word c 2) with
              | None -> ()
              | Some c ->
                  (* the descriptors: the interface (4), its endpoints (5) *)
                  let rec scan o kind found =
                    if o + 2 > String.length c then found
                    else
                      let len = byte c o and typ = byte c (o + 1) in
                      if len = 0 then found
                      else if typ = 4 then
                        scan (o + len) (if byte c (o + 5) = 3 && byte c (o + 6) = 1 then
                                          (match byte c (o + 7) with 1 -> Some Keyboard | 2 -> Some Mouse | _ -> None)
                                        else None) found
                      else if typ = 5 && found = None && kind <> None && byte c (o + 2) land 0x80 <> 0 && byte c (o + 3) land 3 = 3 then
                        scan (o + len) kind (match kind with Some k -> Some (k, byte c (o + 2) land 0xf, word c (o + 4)) | None -> None)
                      else scan (o + len) kind found in
                  match scan 0 None None with
                  | None -> ()
                  | Some (kind, ep, mps) ->
                      let ok r = r <> None in
                      if ok (control addr mps0 set_configuration (byte c 5) 0 0)
                         && ok (control addr mps0 0x210b 0 0 0)     (* SET_PROTOCOL boot *)
                         && ok (control addr mps0 0x210a 0 0 0)     (* SET_IDLE 0 *)
                      then devices := !devices @ [ { addr; ep; mps; kind; toggle = data0; last = String.make 8 '\000' } ]

(* the hub at the root port: address 1, configured; each port powered,
 * then, a device connected, reset and the device set up *)
let hub () =
  let ok r = r <> None in
  match control 0 8 get_descriptor 0x100 0 8 with
  | Some d when byte d 4 = 9 ->
      let mps0 = byte d 7 in
      if ok (control 0 mps0 set_address 1 0 0)
         && ok (control 1 mps0 set_configuration 1 0 0) then begin
        match control 1 mps0 0xa006 0x2900 0 9 with       (* GetHubDescriptor *)
        | Some h ->
            for port = 1 to byte h 2 do
              ignore (control 1 mps0 0x2303 8 port 0);    (* PORT_POWER *)
              match control 1 mps0 0xa300 0 port 4 with   (* GetPortStatus *)
              | Some s when byte s 0 land 1 <> 0 ->
                  ignore (control 1 mps0 0x2303 4 port 0);  (* PORT_RESET *)
                  ignore (control 1 mps0 0x2301 20 port 0); (* C_PORT_RESET *)
                  hid_device ()
              | _ -> ()
            done
        | None -> ()
      end
  | _ -> ()

let init () = if usb_init () then hub ()

(*****************************************************************************)
(* The reports *)
(*****************************************************************************)

(* a US keyboard's keys, by HID usage from 0x04: unshifted, shifted *)
let keys = "abcdefghijklmnopqrstuvwxyz1234567890\r\027\b\t -=[]\\#;'`,./"
let shifted = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()\r\027\b\t _+{}|~:\"~<>?"

(* a key newly down: its character (Control: a letter's low 5 bits) to
 * the console's input *)
let key mods usage =
  if usage >= 0x04 && usage - 0x04 < String.length keys then begin
    let shift = mods land 0x22 <> 0 and ctrl = mods land 0x11 <> 0 in
    let c = (if shift then shifted else keys).[usage - 0x04] in
    let code = if ctrl && Char.lowercase c >= 'a' && Char.lowercase c <= 'z' then Char.code c land 0x1f else Char.code c in
    File.intr code
  end

let report d r =
  match d.kind with
  | Keyboard when String.length r >= 3 ->
      for i = 2 to String.length r - 1 do
        let u = byte r i in
        let rec held j = j < String.length d.last && (byte d.last j = u || held (j + 1)) in
        if u > 1 && not (held 2) then key (byte r 0) u
      done;
      d.last <- r
  | Mouse when String.length r >= 3 ->
      let signed v = if v >= 128 then v - 256 else v in
      Screen.pointer (signed (byte r 1)) (signed (byte r 2)) (byte r 0)
  | _ -> ()

let poll () =
  List.iter (fun d ->
    match transfer d.addr d.ep Interrupt true d.mps d.toggle d.mps with
    | Bytes_moved n ->
        d.toggle <- (if d.toggle = data0 then data1 else data0);
        report d (Phys.read (usb_buffer ()) n)
    | _ -> ()) !devices
