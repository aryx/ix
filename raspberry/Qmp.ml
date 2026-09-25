(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* QEMU's machine protocol, the part xv6's graphical tests use
 * (scripts/qemu_graphics.py): on a Unix socket (-qmp unix:PATH,server,
 * nowait), JSON objects a line each; qmp_capabilities, query-status,
 * screendump (the framebuffer as a PPM file), send-key (keys by QEMU's
 * qcodes, held 100ms of the board's time, or hold-time), quit. Polled
 * between batches of instructions, never blocking. *)

open Ix_raspberry

(* QEMU's qcodes, as USB HID usages *)
let usage_of_qcode q =
  let letters = "abcdefghijklmnopqrstuvwxyz" in
  match q with
  | _ when String.length q = 1 && String.contains letters q.[0] -> Some (4 + String.index letters q.[0])
  | "0" -> Some 0x27
  | _ when String.length q = 1 && q.[0] >= '1' && q.[0] <= '9' -> Some (0x1e + Char.code q.[0] - Char.code '1')
  | "ret" -> Some 0x28 | "esc" -> Some 0x29 | "backspace" -> Some 0x2a | "tab" -> Some 0x2b | "spc" -> Some 0x2c
  | "minus" -> Some 0x2d | "equal" -> Some 0x2e | "bracket_left" -> Some 0x2f | "bracket_right" -> Some 0x30
  | "backslash" -> Some 0x31 | "semicolon" -> Some 0x33 | "apostrophe" -> Some 0x34 | "grave_accent" -> Some 0x35
  | "comma" -> Some 0x36 | "dot" -> Some 0x37 | "slash" -> Some 0x38 | "caps_lock" -> Some 0x39
  | "right" -> Some 0x4f | "left" -> Some 0x50 | "down" -> Some 0x51 | "up" -> Some 0x52
  | "ctrl" -> Some 0xe0 | "shift" -> Some 0xe1 | "alt" -> Some 0xe2 | "ctrl_r" -> Some 0xe4 | "shift_r" -> Some 0xe5 | "alt_r" -> Some 0xe6
  | _ -> None

type t = { server : Unix.file_descr; mutable clients : (Unix.file_descr * Buffer.t) list }

(* "unix:PATH,server,nowait" (or server=on,wait=off) *)
let create spec =
  match String.split_on_char ',' spec with
  | path :: _ when String.length path > 5 && String.sub path 0 5 = "unix:" ->
      let path = String.sub path 5 (String.length path - 5) in
      (try Unix.unlink path with Unix.Unix_error _ -> ());
      let s = Unix.socket PF_UNIX SOCK_STREAM 0 in
      Unix.bind s (ADDR_UNIX path);
      Unix.listen s 4;
      Unix.set_nonblock s;
      { server = s; clients = [] }
  | _ -> failwith ("mini-qemu: -qmp " ^ spec ^ ": only unix:PATH,server,nowait")

let send fd json =
  let s = Yojson.Safe.to_string json ^ "\r\n" in
  ignore (try Unix.write_substring fd s 0 (String.length s) with Unix.Unix_error _ -> 0)

let greeting =
  `Assoc [ "QMP", `Assoc [ "version", `Assoc [ "qemu", `Assoc [ "micro", `Int 0; "minor", `Int 2; "major", `Int 8 ]; "package", `String "mini-qemu" ];
                           "capabilities", `List [] ] ]

let ok = `Assoc [ "return", `Assoc [] ]
let error desc = `Assoc [ "error", `Assoc [ "class", `String "GenericError"; "desc", `String desc ] ]

(* one command, its answer *)
let execute board ~quit json =
  let open Yojson.Safe.Util in
  let args = try member "arguments" json with _ -> `Null in
  match (try member "execute" json |> to_string with _ -> "") with
  | "qmp_capabilities" -> ok
  | "query-status" -> `Assoc [ "return", `Assoc [ "running", `Bool true; "status", `String "running" ] ]
  | "screendump" ->
      (match Board.screen board, (try args |> member "filename" |> to_string with _ -> "") with
       | _, "" -> error "screendump: no filename"
       | None, _ -> error "no framebuffer yet"
       | Some s, f -> Out_channel.with_open_bin f (fun oc -> output_string oc (Framebuffer.ppm s)); ok)
  | "send-key" ->
      let keys = try args |> member "keys" |> to_list with _ -> [] in
      let hold = try args |> member "hold-time" |> to_int with _ -> 100 in
      let usages = List.filter_map (fun k -> try usage_of_qcode (k |> member "data" |> to_string) with _ -> None) keys in
      if List.length usages <> List.length keys then error "send-key: an unknown key"
      else (Board.send_keys board usages ~hold:(hold * 1000); ok)
  | "quit" -> quit (); ok
  | c -> `Assoc [ "error", `Assoc [ "class", `String "CommandNotFound"; "desc", `String ("The command " ^ c ^ " has not been found") ] ]

(* new clients greeted, complete lines run *)
let poll t board ~quit =
  (match Unix.accept t.server with
   | fd, _ -> Unix.set_nonblock fd; send fd greeting; t.clients <- (fd, Buffer.create 256) :: t.clients
   | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> ());
  let buf = Bytes.create 4096 in
  t.clients <- List.filter (fun (fd, b) ->
    match Unix.read fd buf 0 4096 with
    | 0 -> Unix.close fd; false
    | n ->
        Buffer.add_subbytes b buf 0 n;
        let text = Buffer.contents b in
        let lines = String.split_on_char '\n' text in
        let complete = List.filteri (fun i _ -> i < List.length lines - 1) lines in
        Buffer.clear b; Buffer.add_string b (List.nth lines (List.length lines - 1));
        List.iter (fun l ->
          if String.trim l <> "" then
            send fd (try execute board ~quit (Yojson.Safe.from_string l) with Yojson.Json_error m -> error m)) complete;
        true
    | exception Unix.Unix_error ((EAGAIN | EWOULDBLOCK), _, _) -> true
    | exception Unix.Unix_error _ -> Unix.close fd; false) t.clients
