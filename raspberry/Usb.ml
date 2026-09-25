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

type port = { mutable status : int; mutable change : int; dev : device option }

and keyboard = { mutable held : int list; mutable modifiers : int; mutable leds : int; mutable idle : int; mutable protocol : int }

and kind = Hub of port array | Keyboard of keyboard

and device = {
  kind : kind;
  mutable addr : int;
  mutable config : int;
  descriptor : string;
  configuration : string;
  strings : string array;          (* index 1 on; 0 the languages *)
  (* the control transfer in progress, as QEMU's core runs it: its
   * request, its stage, and its data (an IN request's answer, an OUT
   * request's data received) *)
  mutable request_ : int * int * int * int;
  mutable stage : stage;
  mutable buf : string;
}

and stage = Idle | Data_stage | Ack

type result = Data of string | Stall | Nak

(*****************************************************************************)
(* Descriptors *)
(*****************************************************************************)

let bytes l = String.concat "" (List.map (fun b -> String.make 1 (Char.chr (b land 0xff))) l)
let w16 v = [ v land 0xff; (v lsr 8) land 0xff ]

let device_descriptor ~cls ~mps0 ~vendor ~product ~bcd ~imanu ~iprod ~iserial =
  bytes ([ 18; 1 ] @ w16 0x0110 @ [ cls; 0; 0; mps0 ] @ w16 vendor @ w16 product @ w16 bcd @ [ imanu; iprod; iserial; 1 ])

let configuration_descriptor ~iconfig ~attributes ~power ~interface ~extra ~endpoint =
  let body = interface @ extra @ endpoint in
  bytes ([ 9; 2 ] @ w16 (9 + List.length body) @ [ 1; 1; iconfig; attributes; power ] @ body)

let string_descriptor s =
  let u = String.concat "" (List.init (String.length s) (fun i -> bytes [ Char.code s.[i]; 0 ])) in
  bytes [ 2 + String.length u; 3 ] ^ u

(* QEMU's names the device's port path after the serial number *)
let serial s ~path = s ^ "-" ^ path

(* the hub QEMU adds when a device is attached to a one-port controller
 * (hw/usb/dev-hub.c): 8 ports, no power switching *)
let hub ~path devices =
  let ports = Array.init 8 (fun i -> { status = 0x100; change = 0; dev = (if i < List.length devices then Some (List.nth devices i) else None) }) in
  { kind = Hub ports; addr = 0; config = 0; request_ = (0, 0, 0, 0); stage = Idle; buf = "";
    descriptor = device_descriptor ~cls:9 ~mps0:8 ~vendor:0x0409 ~product:0x55aa ~bcd:0x0101 ~imanu:1 ~iprod:2 ~iserial:3;
    configuration = configuration_descriptor ~iconfig:0 ~attributes:0xe0 ~power:0
                      ~interface:[ 9; 4; 0; 0; 1; 9; 0; 0; 0 ] ~extra:[] ~endpoint:([ 7; 5; 0x81; 3 ] @ w16 2 @ [ 0xff ]);
    strings = [| ""; "QEMU"; "QEMU USB Hub"; serial "314159" ~path |] }

let keyboard_report_descriptor = bytes [
  0x05; 0x01; 0x09; 0x06; 0xa1; 0x01; 0x75; 0x01; 0x95; 0x08; 0x05; 0x07; 0x19; 0xe0; 0x29; 0xe7;
  0x15; 0x00; 0x25; 0x01; 0x81; 0x02; 0x95; 0x01; 0x75; 0x08; 0x81; 0x01; 0x95; 0x05; 0x75; 0x01;
  0x05; 0x08; 0x19; 0x01; 0x29; 0x05; 0x91; 0x02; 0x95; 0x01; 0x75; 0x03; 0x91; 0x01; 0x95; 0x06;
  0x75; 0x08; 0x15; 0x00; 0x25; 0xff; 0x05; 0x07; 0x19; 0x00; 0x29; 0xff; 0x81; 0x00; 0xc0 ]

(* QEMU's usb-kbd (hw/usb/dev-hid.c), at full speed *)
let keyboard ~path () =
  { kind = Keyboard { held = []; modifiers = 0; leds = 0; idle = 0; protocol = 1 }; addr = 0; config = 0;
    request_ = (0, 0, 0, 0); stage = Idle; buf = "";
    descriptor = device_descriptor ~cls:0 ~mps0:8 ~vendor:0x0627 ~product:0x0001 ~bcd:0 ~imanu:1 ~iprod:4 ~iserial:11;
    configuration = configuration_descriptor ~iconfig:8 ~attributes:0xa0 ~power:50
                      ~interface:[ 9; 4; 0; 0; 1; 3; 1; 1; 0 ]
                      ~extra:([ 9; 0x21; 0x11; 0x01; 0; 1; 0x22 ] @ w16 (String.length keyboard_report_descriptor))
                      ~endpoint:([ 7; 5; 0x81; 3 ] @ w16 8 @ [ 0x0a ]);
    strings = [| ""; "QEMU"; "QEMU USB Mouse"; "QEMU USB Tablet"; "QEMU USB Keyboard"; "42"; "HID Mouse"; "HID Tablet";
                 "HID Keyboard"; "89126"; "28754"; serial "68284" ~path |] }

(*****************************************************************************)
(* Resets, the hub's ports *)
(*****************************************************************************)

(* a port's status bit set or cleared; the low five are changes too *)
let port_set p bit = if p.status land bit = 0 then (p.status <- p.status lor bit; if bit land 0x1f <> 0 then p.change <- p.change lor bit)
let port_clear p bit = if p.status land bit <> 0 then (p.status <- p.status land lnot bit; if bit land 0x1f <> 0 then p.change <- p.change lor bit)

let reset d =
  d.addr <- 0; d.config <- 0; d.stage <- Idle; d.buf <- "";
  match d.kind with
  | Hub ports ->
      Array.iter (fun p ->
        p.status <- 0x100; p.change <- 0;
        (* a device attached: connected, a change *)
        if p.dev <> None then port_set p 1) ports
  | Keyboard k -> k.idle <- 0; k.protocol <- 1

(* the device of an address, through the enabled ports of hubs *)
let rec find d addr =
  if d.addr = addr then Some d
  else match d.kind with
    | Hub ports ->
        Array.fold_left (fun acc p ->
          match acc, p.dev with
          | Some _, _ -> acc
          | None, Some c when p.status land 2 <> 0 -> find c addr
          | _ -> None) None ports
    | Keyboard _ -> None

(*****************************************************************************)
(* Control requests *)
(*****************************************************************************)

(* the keyboard's report: modifiers, a reserved byte, six keys *)
let report k =
  let keys = List.filteri (fun i _ -> i < 6) (List.rev k.held) in
  bytes ([ k.modifiers; 0 ] @ keys @ List.init (6 - List.length keys) (fun _ -> 0))

(* a request (bmRequestType << 8 | bRequest): its answer (IN) or its
 * effect (OUT, with its data), or Stall *)
let request d ~req ~value ~index ~data =
  let standard () =
    match req with
    | 0x8006 ->
        (match value lsr 8, value land 0xff with
         | 1, _ -> Data d.descriptor
         | 2, _ -> Data d.configuration
         | 3, 0 -> Data (bytes [ 4; 3; 0x09; 0x04 ])
         | 3, i when i < Array.length d.strings && d.strings.(i) <> "" -> Data (string_descriptor d.strings.(i))
         | _ -> Stall)
    | 0x0005 -> d.addr <- value land 0x7f; Data ""
    | 0x0009 -> d.config <- value land 0xff; Data ""
    | 0x8008 -> Data (bytes [ d.config ])
    | 0x8000 -> Data (bytes [ (if Char.code d.configuration.[7] land 0x40 <> 0 then 1 else 0); 0 ])
    | 0x8100 | 0x8200 -> Data (bytes [ 0; 0 ])
    | 0x0001 | 0x0003 | 0x0102 | 0x0201 -> Data ""
    | 0x810a -> Data (bytes [ 0 ])
    | 0x010b -> Data ""
    | _ -> Stall in
  match d.kind with
  | Hub ports ->
      let port () = if index >= 1 && index <= Array.length ports then Some ports.(index - 1) else None in
      (match req, port () with
       | 0xa000, _ -> Data (bytes [ 0; 0; 0; 0 ])                     (* GetHubStatus *)
       | 0xa300, Some p -> Data (bytes (w16 p.status @ w16 p.change))  (* GetPortStatus *)
       | 0xa006, _ ->                                                  (* GetHubDescriptor *)
           let d = [ 0; 0x29; Array.length ports; 0x0a; 0; 1; 0; 0; 0; 0xff ] in
           let d = List.length d :: List.tl d in
           Data (bytes d)
       | (0x2003 | 0x2001), _ -> if value = 0 || value = 1 then Data "" else Stall
       | 0x2303, Some p ->                                             (* SetPortFeature *)
           (match value with
            | 2 -> p.status <- p.status lor 4; Data ""
            | 4 ->
                port_set p 0x10; port_clear p 0x10;
                (match p.dev with Some c -> reset c; port_set p 2 | None -> ());
                Data ""
            | 8 -> Data ""
            | _ -> Stall)
       | 0x2301, Some p ->                                             (* ClearPortFeature *)
           (match value with
            | 1 -> p.status <- p.status land lnot 2; Data ""
            | 2 -> port_clear p 4; Data ""
            | 16 -> p.change <- p.change land lnot 1; Data ""
            | 17 -> p.change <- p.change land lnot 2; Data ""
            | 18 -> p.change <- p.change land lnot 4; Data ""
            | 19 -> p.change <- p.change land lnot 8; Data ""
            | 20 -> p.change <- p.change land lnot 0x10; Data ""
            | 8 -> Data ""
            | _ -> Stall)
       | _ -> standard ())
  | Keyboard k ->
      (match req with
       | 0x8106 when value lsr 8 = 0x22 -> Data keyboard_report_descriptor
       | 0x8106 when value lsr 8 = 0x21 -> Data (String.sub d.configuration 18 9)
       | 0xa101 -> Data (report k)                                     (* GET_REPORT *)
       | 0x2109 -> if String.length data > 0 then k.leds <- Char.code data.[0]; Data ""  (* SET_REPORT *)
       | 0xa102 -> Data (bytes [ k.idle ])
       | 0x210a -> k.idle <- value lsr 8; Data ""
       | 0xa103 -> Data (bytes [ k.protocol ])
       | 0x210b -> k.protocol <- value; Data ""
       | _ -> standard ())

(* endpoint 0's packets, QEMU's core's state machine (hw/usb/core.c):
 * an IN request runs at its SETUP, its answer then read by the data
 * stage; an OUT request runs at its status stage (so that SET_ADDRESS
 * completes at the address it had) with the data its data stage
 * brought *)
let setup d packet =
  let b i = Char.code packet.[i] in
  let req = (b 0 lsl 8) lor b 1 and value = b 2 lor (b 3 lsl 8) and index = b 4 lor (b 5 lsl 8) and length = b 6 lor (b 7 lsl 8) in
  d.request_ <- (req, value, index, length);
  d.buf <- "";
  if b 0 land 0x80 <> 0 then
    match request d ~req ~value ~index ~data:"" with
    | Data s -> d.buf <- (if String.length s > length then String.sub s 0 length else s); d.stage <- Data_stage; Data ""
    | r -> r
  else (d.stage <- (if length = 0 then Ack else Data_stage); Data "")

let data_in d len =
  let req, value, index, _ = d.request_ in
  match d.stage with
  | Ack when req land 0x8000 = 0 ->
      d.stage <- Idle;
      (match request d ~req ~value ~index ~data:d.buf with Data _ -> Data "" | r -> r)
  | Ack -> Data ""
  | Data_stage when req land 0x8000 <> 0 ->
      let n = min len (String.length d.buf) in
      let s = String.sub d.buf 0 n in
      d.buf <- String.sub d.buf n (String.length d.buf - n);
      if d.buf = "" then d.stage <- Ack;
      Data s
  | _ -> d.stage <- Idle; Stall

let data_out d data =
  let req, _, _, length = d.request_ in
  match d.stage with
  | Ack -> if req land 0x8000 <> 0 then d.stage <- Idle; Data ""
  | Data_stage when req land 0x8000 = 0 ->
      d.buf <- d.buf ^ data;
      if String.length d.buf >= length then d.stage <- Ack;
      Data ""
  | _ -> d.stage <- Idle; Stall

(*****************************************************************************)
(* The keyboard's keys *)
(*****************************************************************************)

let key d usage down =
  match d.kind with
  | Keyboard k ->
      if usage >= 0xe0 && usage <= 0xe7 then
        k.modifiers <- (if down then k.modifiers lor (1 lsl (usage - 0xe0)) else k.modifiers land lnot (1 lsl (usage - 0xe0)))
      else if down then (if not (List.mem usage k.held) then k.held <- usage :: k.held)
      else k.held <- List.filter (( <> ) usage) k.held
  | Hub _ -> ()

let leds d = match d.kind with Keyboard k -> k.leds | Hub _ -> 0
