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

(* what QEMU's HID devices share (hw/input/hid.c's HIDState): the idle
 * rate (4ms units), when the next idle report is due (microseconds of
 * the board's time, -1 none) and whether it is, the protocol *)
and hid = {
  mutable idle : int;
  mutable idle_at : int;
  mutable idle_pending : bool;
  mutable protocol : int;
}

(* QEMU's keyboard: the events queued (QUEUE_LENGTH 16) as its PS/2
 * scancodes are, an extended key's 0xe0 prefix one of its own; the keys
 * held (key[16], a release swapping the last one into its place), the
 * modifiers, the LEDs *)
and keyboard = {
  key : int array;
  mutable keys : int;
  mutable modifiers : int;
  queue : event Queue.t;
  mutable leds : int;
}

and event = Prefix | Usage of int * bool

(* QEMU's mouse: a ring of 16 events (motion, wheel, buttons), [n] of
 * them the guest's to read from [head]; the one at head + n being made
 * by the host's input until a sync publishes it (or adds it to the one
 * before, when the buttons are the same) *)
and mouse = {
  events : pointer array;
  mutable head : int;
  mutable n : int;
}

and pointer = { mutable xdx : int; mutable ydy : int; mutable dz : int; mutable buttons : int }

and kind = Hub of port array | Keyboard of keyboard * hid | Mouse of mouse * hid

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

type result = Data of string | Stall | Nak | Babble

(*****************************************************************************)
(* Descriptors *)
(*****************************************************************************)

let bytes l = String.concat "" (List.map (fun b -> String.make 1 (Char.chr (b land 0xff))) l)
let w16 v = [ v land 0xff; (v lsr 8) land 0xff ]

(* [usb]: bcdUSB, 0x0110 the hub's, 0x0100 the HID devices' (claude:
 * the keyboard's said 0x0110 before) *)
let device_descriptor ~usb ~cls ~mps0 ~vendor ~product ~bcd ~imanu ~iprod ~iserial =
  bytes ([ 18; 1 ] @ w16 usb @ [ cls; 0; 0; mps0 ] @ w16 vendor @ w16 product @ w16 bcd @ [ imanu; iprod; iserial; 1 ])

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
    descriptor = device_descriptor ~usb:0x0110 ~cls:9 ~mps0:8 ~vendor:0x0409 ~product:0x55aa ~bcd:0x0101 ~imanu:1 ~iprod:2 ~iserial:3;
    configuration = configuration_descriptor ~iconfig:0 ~attributes:0xe0 ~power:0
                      ~interface:[ 9; 4; 0; 0; 1; 9; 0; 0; 0 ] ~extra:[] ~endpoint:([ 7; 5; 0x81; 3 ] @ w16 2 @ [ 0xff ]);
    strings = [| ""; "QEMU"; "QEMU USB Hub"; serial "314159" ~path |] }

let keyboard_report_descriptor = bytes [
  0x05; 0x01; 0x09; 0x06; 0xa1; 0x01; 0x75; 0x01; 0x95; 0x08; 0x05; 0x07; 0x19; 0xe0; 0x29; 0xe7;
  0x15; 0x00; 0x25; 0x01; 0x81; 0x02; 0x95; 0x01; 0x75; 0x08; 0x81; 0x01; 0x95; 0x05; 0x75; 0x01;
  0x05; 0x08; 0x19; 0x01; 0x29; 0x05; 0x91; 0x02; 0x95; 0x01; 0x75; 0x03; 0x91; 0x01; 0x95; 0x06;
  0x75; 0x08; 0x15; 0x00; 0x25; 0xff; 0x05; 0x07; 0x19; 0x00; 0x29; 0xff; 0x81; 0x00; 0xc0 ]

(* QEMU's mouse's report: 5 buttons, 3 bits of padding, X, Y and the
 * wheel relative (-127 to 127) *)
let mouse_report_descriptor = bytes [
  0x05; 0x01; 0x09; 0x02; 0xa1; 0x01; 0x09; 0x01; 0xa1; 0x00; 0x05; 0x09; 0x19; 0x01; 0x29; 0x05;
  0x15; 0x00; 0x25; 0x01; 0x95; 0x05; 0x75; 0x01; 0x81; 0x02; 0x95; 0x01; 0x75; 0x03; 0x81; 0x01;
  0x05; 0x01; 0x09; 0x30; 0x09; 0x31; 0x09; 0x38; 0x15; 0x81; 0x25; 0x7f; 0x75; 0x08; 0x95; 0x03;
  0x81; 0x06; 0xc0; 0xc0 ]

(* dev-hid.c's strings, all of them in each device's table *)
let hid_strings ~serial_index ~path =
  let s = [| ""; "QEMU"; "QEMU USB Mouse"; "QEMU USB Tablet"; "QEMU USB Keyboard"; "42"; "HID Mouse"; "HID Tablet";
             "HID Keyboard"; "89126"; "28754"; "68284" |] in
  s.(serial_index) <- serial s.(serial_index) ~path;
  s

let new_hid () = { idle = 0; idle_at = -1; idle_pending = false; protocol = 1 }

(* QEMU's usb-kbd (hw/usb/dev-hid.c), at full speed *)
let keyboard ~path () =
  { kind = Keyboard ({ key = Array.make 16 0; keys = 0; modifiers = 0; queue = Queue.create (); leds = 0 }, new_hid ());
    addr = 0; config = 0; request_ = (0, 0, 0, 0); stage = Idle; buf = "";
    descriptor = device_descriptor ~usb:0x0100 ~cls:0 ~mps0:8 ~vendor:0x0627 ~product:0x0001 ~bcd:0 ~imanu:1 ~iprod:4 ~iserial:11;
    configuration = configuration_descriptor ~iconfig:8 ~attributes:0xa0 ~power:50
                      ~interface:[ 9; 4; 0; 0; 1; 3; 1; 1; 0 ]
                      ~extra:([ 9; 0x21; 0x11; 0x01; 0; 1; 0x22 ] @ w16 (String.length keyboard_report_descriptor))
                      ~endpoint:([ 7; 5; 0x81; 3 ] @ w16 8 @ [ 0x0a ]);
    strings = hid_strings ~serial_index:11 ~path }

(* QEMU's usb-mouse (dev-hid.c's desc_mouse), at full speed *)
let mouse ~path () =
  { kind = Mouse ({ events = Array.init 16 (fun _ -> { xdx = 0; ydy = 0; dz = 0; buttons = 0 }); head = 0; n = 0 }, new_hid ());
    addr = 0; config = 0; request_ = (0, 0, 0, 0); stage = Idle; buf = "";
    descriptor = device_descriptor ~usb:0x0100 ~cls:0 ~mps0:8 ~vendor:0x0627 ~product:0x0001 ~bcd:0 ~imanu:1 ~iprod:2 ~iserial:9;
    configuration = configuration_descriptor ~iconfig:6 ~attributes:0xa0 ~power:50
                      ~interface:[ 9; 4; 0; 0; 1; 3; 1; 2; 0 ]
                      ~extra:([ 9; 0x21; 0x01; 0x00; 0; 1; 0x22 ] @ w16 (String.length mouse_report_descriptor))
                      ~endpoint:([ 7; 5; 0x81; 3 ] @ w16 4 @ [ 0x0a ]);
    strings = hid_strings ~serial_index:9 ~path }

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
  | Keyboard (k, h) ->
      (* hid_reset *)
      Array.fill k.key 0 16 0; k.keys <- 0; k.modifiers <- 0; Queue.clear k.queue;
      h.idle <- 0; h.protocol <- 1; h.idle_at <- -1; h.idle_pending <- false
  | Mouse (m, h) ->
      Array.iter (fun e -> e.xdx <- 0; e.ydy <- 0; e.dz <- 0; e.buttons <- 0) m.events;
      m.head <- 0; m.n <- 0;
      h.idle <- 0; h.protocol <- 1; h.idle_at <- -1; h.idle_pending <- false

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
    | Keyboard _ | Mouse _ -> None

(*****************************************************************************)
(* The HID devices' reports (hw/input/hid.c) *)
(*****************************************************************************)

(* one queued event applied (hid_keyboard_process_keycode): a modifier
 * set or cleared, a key added (at the end, 16 at most) or removed (the
 * last moved into its place); a prefix, nothing *)
let process k =
  match Queue.take_opt k.queue with
  | None | Some Prefix -> ()
  | Some (Usage (u, down)) ->
      if u >= 0xe0 && u <= 0xe7 then
        k.modifiers <- (if down then k.modifiers lor (1 lsl (u - 0xe0)) else k.modifiers land lnot (1 lsl (u - 0xe0)))
      else begin
        let rec find i = if i < 0 then -1 else if k.key.(i) = u then i else find (i - 1) in
        let i = find (k.keys - 1) in
        if down then (if i < 0 && k.keys < 16 then (k.key.(k.keys) <- u; k.keys <- k.keys + 1))
        else if i >= 0 then begin
          k.keys <- k.keys - 1;
          k.key.(i) <- k.key.(k.keys);
          k.key.(k.keys) <- 0
        end
      end

(* a report (hid_keyboard_poll): one event applied, then the modifiers,
 * a reserved byte, six keys (more held: 0x01, the rollover error), [len]
 * bytes of it at most *)
let keyboard_poll k h len =
  h.idle_pending <- false;
  if len < 2 then ""
  else begin
    process k;
    let keys = List.init 6 (fun i -> if k.keys > 6 then 1 else k.key.(i)) in
    let r = bytes ([ k.modifiers; 0 ] @ keys) in
    String.sub r 0 (min 8 len)
  end

(* a report (hid_pointer_poll): the oldest event the guest has not read
 * (none: the last one, its motion spent), up to 127 of its motion (the
 * rest the next report's), the wheel inverted; the event done with once
 * all of it is reported *)
let mouse_poll m h len =
  h.idle_pending <- false;
  let e = m.events.((if m.n > 0 then m.head else m.head - 1) land 15) in
  let clamp v = max (-127) (min 127 v) in
  let dx = clamp e.xdx and dy = clamp e.ydy and dz = clamp e.dz in
  e.xdx <- e.xdx - dx; e.ydy <- e.ydy - dy; e.dz <- e.dz - dz;
  if m.n > 0 && e.dz = 0 && e.xdx = 0 && e.ydy = 0 then begin m.head <- m.head + 1; m.n <- m.n - 1 end;
  let r = bytes [ e.buttons; dx; dy; - dz ] in
  String.sub r 0 (min 4 len)

(* the idle timer (hid_set_next_idle): the next report due idle * 4ms on,
 * or none *)
let set_next_idle h ~now = h.idle_at <- (if h.idle > 0 then now + (h.idle * 4000) else -1)

(* an idle report due, then due (hid_idle_timer) *)
let idle_due h ~now = if h.idle_at >= 0 && now >= h.idle_at then (h.idle_pending <- true; h.idle_at <- -1)

(* a device's HID state, its report descriptor, a report (hid_has_events
 * decides whether an interrupt IN gets one), whether events wait *)
let hid d =
  match d.kind with
  | Keyboard (k, h) -> Some (h, keyboard_report_descriptor, keyboard_poll k h, fun () -> not (Queue.is_empty k.queue))
  | Mouse (m, h) -> Some (h, mouse_report_descriptor, mouse_poll m h, fun () -> m.n > 0)
  | Hub _ -> None

(*****************************************************************************)
(* Control requests *)
(*****************************************************************************)

(* a request (bmRequestType << 8 | bRequest): its answer (IN) or its
 * effect (OUT, with its data), or Stall *)
let request d ~now ~req ~value ~index ~data =
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
  | Keyboard _ | Mouse _ ->
      let h, descriptor, poll, _ = Option.get (hid d) in
      (match req, d.kind with
       | 0x8106, _ when value lsr 8 = 0x22 -> Data descriptor
       | 0x8106, _ when value lsr 8 = 0x21 -> Data (String.sub d.configuration 18 9)
       | 0xa101, _ -> Data (poll 8)                                    (* GET_REPORT *)
       | 0x2109, Keyboard (k, _) -> if String.length data > 0 then k.leds <- Char.code data.[0]; Data ""  (* SET_REPORT *)
       | 0xa102, _ -> Data (bytes [ h.idle ])
       | 0x210a, _ ->
           h.idle <- value lsr 8;
           set_next_idle h ~now;
           Data ""
       | 0xa103, _ -> Data (bytes [ h.protocol ])
       | 0x210b, _ -> h.protocol <- value; Data ""
       | _ -> standard ())

(* endpoint 0's packets, QEMU's core's state machine (hw/usb/core.c):
 * an IN request runs at its SETUP, its answer then read by the data
 * stage; an OUT request runs at its status stage (so that SET_ADDRESS
 * completes at the address it had) with the data its data stage
 * brought *)
let setup d ~now packet =
  let b i = Char.code packet.[i] in
  let req = (b 0 lsl 8) lor b 1 and value = b 2 lor (b 3 lsl 8) and index = b 4 lor (b 5 lsl 8) and length = b 6 lor (b 7 lsl 8) in
  d.request_ <- (req, value, index, length);
  d.buf <- "";
  if b 0 land 0x80 <> 0 then
    match request d ~now ~req ~value ~index ~data:"" with
    | Data s -> d.buf <- (if String.length s > length then String.sub s 0 length else s); d.stage <- Data_stage; Data ""
    | r -> r
  else (d.stage <- (if length = 0 then Ack else Data_stage); Data "")

(* endpoint 1's (usb_hid_handle_data, usb_hub_handle_data): the
 * keyboard's report when an event is queued or an idle report due (the
 * next idle then set), else NAK; the hub's ports with a change, a
 * bitmap (bit i + 1 port i's), else NAK; BABBLE when it does not fit *)
let interrupt_in d ~now len =
  match d.kind with
  | Keyboard _ | Mouse _ ->
      let h, _, poll, waiting = Option.get (hid d) in
      idle_due h ~now;
      if not (waiting () || h.idle_pending) then Nak
      else begin set_next_idle h ~now; Data (poll len) end
  | Hub ports ->
      let n = if len = 1 then 1 else (Array.length ports + 1 + 7) / 8 in
      if n > len then Babble
      else begin
        let status = ref 0 in
        Array.iteri (fun i p -> if p.change <> 0 then status := !status lor (1 lsl (i + 1))) ports;
        if !status = 0 then Nak else Data (bytes (List.init n (fun i -> !status lsr (8 * i))))
      end

let data_in d ~now ~ep len =
  let req, value, index, _ = d.request_ in
  if ep = 1 then interrupt_in d ~now len
  else if ep <> 0 then Stall
  else match d.stage with
  | Ack when req land 0x8000 = 0 ->
      d.stage <- Idle;
      (match request d ~now ~req ~value ~index ~data:d.buf with Data _ -> Data "" | r -> r)
  | Ack -> Data ""
  | Data_stage when req land 0x8000 <> 0 ->
      let n = min len (String.length d.buf) in
      let s = String.sub d.buf 0 n in
      d.buf <- String.sub d.buf n (String.length d.buf - n);
      if d.buf = "" then d.stage <- Ack;
      Data s
  | _ -> d.stage <- Idle; Stall

let data_out d ~ep data =
  let req, _, _, length = d.request_ in
  if ep <> 0 then Stall
  else match d.stage with
  | Ack -> if req land 0x8000 <> 0 then d.stage <- Idle; Data ""
  | Data_stage when req land 0x8000 = 0 ->
      d.buf <- d.buf ^ data;
      if String.length d.buf >= length then d.stage <- Ack;
      Data ""
  | _ -> d.stage <- Idle; Stall

(*****************************************************************************)
(* The keyboard's keys *)
(*****************************************************************************)

(* the keys PS/2 sends with an 0xe0 prefix (QEMU queues its scancodes):
 * Insert to Up, keypad / and Enter, the right Control, Alt, the GUI
 * keys, Menu *)
let extended u = (u >= 0x49 && u <= 0x52) || u = 0x54 || u = 0x58 || u = 0xe4 || u = 0xe6 || u = 0xe3 || u = 0xe7 || u = 0x65

(* a key event queued (hid_keyboard_event), dropped when the queue has
 * no room for it *)
let key d usage down =
  match d.kind with
  | Keyboard (k, _) ->
      let events = (if extended usage then [ Prefix ] else []) @ [ Usage (usage, down) ] in
      if Queue.length k.queue + List.length events <= 16 then List.iter (fun e -> Queue.add e k.queue) events
  | Hub _ | Mouse _ -> ()

let leds d = match d.kind with Keyboard (k, _) -> k.leds | Hub _ | Mouse _ -> 0

(*****************************************************************************)
(* The mouse's motion and buttons *)
(*****************************************************************************)

type input = Rel_x of int | Rel_y of int | Button of int * bool | Wheel of int

(* the host's input events, added to the event being made
 * (hid_pointer_event: a button by its bit, 1 left, 2 right, 4 middle;
 * the wheel up -1), then a sync (hid_pointer_sync): the event added to
 * the unread one before it when the buttons are the same, else
 * published, the next one begun with its buttons (none when the ring is
 * full: the motion lost, the buttons kept) *)
let pointer d inputs =
  match d.kind with
  | Mouse (m, _) ->
      let at k = m.events.((m.head + m.n + k) land 15) in
      let cur = at 0 in
      List.iter (function
        | Rel_x v -> cur.xdx <- cur.xdx + v
        | Rel_y v -> cur.ydy <- cur.ydy + v
        | Button (b, down) -> cur.buttons <- (if down then cur.buttons lor b else cur.buttons land lnot b)
        | Wheel v -> cur.dz <- cur.dz + v) inputs;
      if m.n <> 15 then begin
        let prev = at (-1) and next = at 1 in
        if m.n > 0 && cur.buttons = prev.buttons then begin
          prev.xdx <- prev.xdx + cur.xdx; cur.xdx <- 0;
          prev.ydy <- prev.ydy + cur.ydy; cur.ydy <- 0;
          prev.dz <- prev.dz + cur.dz; cur.dz <- 0
        end
        else begin
          next.xdx <- 0; next.ydy <- 0; next.dz <- 0;
          next.buttons <- cur.buttons;
          m.n <- m.n + 1
        end
      end
  | Hub _ | Keyboard _ -> ()
