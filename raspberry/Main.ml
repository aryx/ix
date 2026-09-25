(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* tinypi: QEMU's command line, the part the Pi kernels' Makefiles use
 * (plan_pi.md, "The kernels it must boot"):
 *
 *     tinypi -M raspi1ap -nographic -kernel kernel.img
 *
 * -M/-machine (raspi1ap), -kernel, -m (ignored: the board's 512MB),
 * -nographic, -serial and -monitor (the UART on standard input and
 * output either way), -smp, -device, -append, -no-reboot (accepted,
 * ignored); our own: -ips N (instructions per simulated microsecond,
 * default 30), -d (log unassigned I/O and undefined instructions to
 * standard error). On a terminal, standard input is raw and Ctrl-A x
 * quits, as QEMU's -nographic. *)

open Ix_raspberry

let usage = "usage: tinypi -M raspi1ap [-nographic] -kernel image [-ips N] [-d]"

let main (caps : < Cap.argv; Cap.open_in; Cap.stdin; Cap.stdout; Cap.stderr; .. >) =
  let args = List.tl (Array.to_list (CapSys.argv caps)) in
  let kernel = ref None and machine = ref "" and ips = ref 30 and debug = ref false and kbd = ref false in
  let qmp = ref None and graphics = ref true in
  let rec parse = function
    | [] -> ()
    | ("-M" | "-machine") :: m :: rest -> machine := List.hd (String.split_on_char ',' m); parse rest
    | "-kernel" :: k :: rest -> kernel := Some k; parse rest
    | "-ips" :: n :: rest -> ips := int_of_string n; parse rest
    | "-d" :: rest -> debug := true; parse rest
    | "-device" :: d :: rest when List.hd (String.split_on_char ',' d) = "usb-kbd" -> kbd := true; parse rest
    | "-qmp" :: q :: rest -> qmp := Some q; parse rest
    | "-display" :: "none" :: rest -> graphics := false; parse rest
    | "-nographic" :: rest -> graphics := false; parse rest
    | ("-m" | "-serial" | "-monitor" | "-smp" | "-device" | "-append" | "-D" | "-display") :: _ :: rest -> parse rest
    | ("-no-reboot" | "-S") :: rest -> parse rest
    | a :: _ -> Console.eprint caps (Printf.sprintf "tinypi: unknown option %s\n%s\n" a usage); exit 2 in
  parse args;
  match !kernel with
  | None -> Console.eprint caps (usage ^ "\n"); 2
  | Some _ when !machine <> "raspi1ap" -> Console.eprint caps (Printf.sprintf "tinypi: machine %s not (yet) supported\n" !machine); 2
  | Some k ->
      let log s = if !debug then Console.eprint caps ("tinypi: " ^ s ^ "\n") in
      let out = Buffer.create 256 in
      let board = Board.create { ram_size = 512 * 1024 * 1024; ips = !ips; log; usb_keyboard = !kbd } ~output:(Buffer.add_char out) in
      (match Files.read caps (Fpath.v k) with
       | image -> Board.load_kernel board image
       | exception Sys_error m -> Console.eprint caps ("tinypi: " ^ m ^ "\n"); exit 1);
      (* standard input: raw on a terminal (Ctrl-A x to quit), polled *)
      let tty = Unix.isatty Unix.stdin in
      let saved = if tty then Some (Unix.tcgetattr Unix.stdin) else None in
      Option.iter (fun (a : Unix.terminal_io) ->
        Unix.tcsetattr Unix.stdin TCSANOW { a with c_icanon = false; c_echo = false; c_isig = false; c_icrnl = false; c_vmin = 1 }) saved;
      let restore () = Option.iter (fun a -> Unix.tcsetattr Unix.stdin TCSANOW a) saved in
      let open_input = ref true and ctrl_a = ref false in
      let buf = Bytes.create 256 in
      let poll () =
        if !open_input then
          match Unix.select [ Unix.stdin ] [] [] 0.0 with
          | [ _ ], _, _ ->
              let n = try Unix.read Unix.stdin buf 0 256 with Unix.Unix_error _ -> 0 in
              if n = 0 then open_input := false;
              for i = 0 to n - 1 do
                let c = Bytes.get buf i in
                if tty && !ctrl_a && c = 'x' then (restore (); Console.print caps "\nQEMU: Terminated\n"; exit 0);
                ctrl_a := tty && c = '\001';
                if not !ctrl_a then Board.input board c
              done
          | _ -> () in
      (* the window, unless -nographic or no display; QMP's socket *)
      let display =
        if !graphics && Sys.getenv_opt "DISPLAY" <> None then Sdl_display.create ~title:"tinypi" else Display.none in
      let qmp = Option.map Qmp.create !qmp in
      let quit () = restore (); exit 0 in
      let last_frame = ref 0. in
      let n = ref 0 in
      (try
         while true do
           Board.run board ~batch:4096;
           if Buffer.length out > 0 then (Console.print caps (Buffer.contents out); flush stdout; Buffer.clear out);
           incr n;
           if !n land 15 = 0 then begin
             poll ();
             Option.iter (fun q -> Qmp.poll q board ~quit) qmp;
             (* the screen, 30 times a second of the host's *)
             let now = Unix.gettimeofday () in
             if now -. !last_frame > 1. /. 30. then begin
               last_frame := now;
               Option.iter (fun (g, data) -> display.present g data) (Board.frame board);
               List.iter (function Display.Key (u, down) -> Board.key board u down | Display.Quit -> quit ()) (display.poll ())
             end
           end
         done
       with e -> restore (); raise e);
      0

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
