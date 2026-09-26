(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devmouse.mli *)

open Types

let qdir = 0 and qcursor = 1 and qmouse = 2 and qmousein = 3 and qmousectl = 4
let root = { path = qdir; vers = 0; typ = Qt_dir }

let fq p = { path = p; vers = 0; typ = Qt_file }
let entries path =
  if path <> qdir then raise (Error enotdir)
  else [ { Dev.dname = "cursor"; Dev.dqid = fq qcursor; Dev.dlength = 0; Dev.dperm = 0o666 };
         { Dev.dname = "mouse"; Dev.dqid = fq qmouse; Dev.dlength = 0; Dev.dperm = 0o666 };
         { Dev.dname = "mousein"; Dev.dqid = fq qmousein; Dev.dlength = 0; Dev.dperm = 0o220 };
         { Dev.dname = "mousectl"; Dev.dqid = fq qmousectl; Dev.dlength = 0; Dev.dperm = 0o220 } ]

let screen = ref None

(* the mouse's state (Mousestate) *)
type state = { x : int; y : int; buttons : int; counter : int; msec : int }

let st = ref { x = 0; y = 0; buttons = 0; counter = 0; msec = 0 }
let lastcounter = ref 0
let resize = ref 0
let lastresize = ref 0
let is_open = ref false
let acceleration = ref 0
let maxacc = ref 2
(* the clicks queued (16 at most: full, none until a read) *)
let queue = ref []
let qfull = ref false
let buttonmap = Array.init 8 (fun i -> i)
let mouseswap = ref false
let scrollswap = ref false
let kbdbuttons = ref 0
let mousetime = ref 0

(* the cursor's image: its offset, clr and set (2 x 16 x 16 bits) *)
let arrow =
  let b l = String.concat "" (List.map (fun v -> String.make 1 (Char.chr v)) l) in
  Machine.le32 (-1) ^ Machine.le32 (-1)
  ^ b [ 0xFF; 0xFF; 0x80; 0x01; 0x80; 0x02; 0x80; 0x0C; 0x80; 0x10; 0x80; 0x10; 0x80; 0x08; 0x80; 0x04;
        0x80; 0x02; 0x80; 0x01; 0x80; 0x02; 0x8C; 0x04; 0x92; 0x08; 0x91; 0x10; 0xA0; 0xA0; 0xC0; 0x40 ]
  ^ b [ 0x00; 0x00; 0x7F; 0xFE; 0x7F; 0xFC; 0x7F; 0xF0; 0x7F; 0xE0; 0x7F; 0xE0; 0x7F; 0xF0; 0x7F; 0xF8;
        0x7F; 0xFC; 0x7F; 0xFE; 0x7F; 0xFC; 0x73; 0xF8; 0x61; 0xF0; 0x60; 0xE0; 0x40; 0x40; 0x00; 0x00 ]

(* the offset, as BPLONG writes it: big-endian *)
let bplong v = let s = Machine.le32 v in String.make 1 s.[3] ^ String.make 1 s.[2] ^ String.make 1 s.[1] ^ String.make 1 s.[0]
let cursor = ref (bplong (-1) ^ bplong (-1) ^ String.sub arrow 8 64)

let scale x =
  let sign = if x < 0 then -1 else 1 and x = abs x in
  sign * (if x <= 3 then x else if x = 4 then 6 + (!acceleration asr 2) else if x = 5 then 9 + (!acceleration asr 1) else x * !maxacc)

(* mousetrack: a move, clamped to the screen; a button's change queued *)
let mousetrack dx dy b msec =
  match !screen with
  | None -> ()
  | Some (x0, y0, x1, y1) ->
      let dx, dy = if !acceleration <> 0 then scale dx, scale dy else dx, dy in
      let clamp v lo hi = if v < lo then lo else if v >= hi then hi else v in
      let lastb = !st.buttons in
      st := { x = clamp (!st.x + dx) x0 x1; y = clamp (!st.y + dy) y0 y1; buttons = b lor !kbdbuttons;
              counter = !st.counter + 1; msec = msec };
      if not !qfull && lastb <> b then begin
        queue := !queue @ [ !st ];
        if List.length !queue = 16 then qfull := true
      end;
      Proc.wakeup Mouse_change

let changed () = !lastcounter <> !st.counter || !lastresize <> !resize

let now_ms () = !Proc.ticks * 10

(* strtol over "m x y b msec": the numbers after the first byte *)
let numbers s =
  let s = String.sub s 1 (String.length s - 1) in
  List.map (fun w -> try int_of_string w with Failure _ -> 0)
    (List.filter (fun w -> w <> "") (String.split_on_char ' ' (String.map (fun c -> if c = '\n' || c = '\t' then ' ' else c) s)))

let setbuttonmap map =
  if String.length map <> 3 then raise (Error ebadarg);
  let one = ref 0 and two = ref 0 and three = ref 0 in
  for i = 0 to 2 do
    let r = match map.[i] with '1' -> one | '2' -> two | '3' -> three | _ -> raise (Error ebadarg) in
    if !r <> 0 then raise (Error ebadarg);
    r := 1 lsl i
  done;
  Array.fill buttonmap 0 8 0;
  for i = 0 to 7 do
    let x = (if i land 1 <> 0 then !one else 0) lor (if i land 2 <> 0 then !two else 0) lor (if i land 4 <> 0 then !three else 0) in
    buttonmap.(x) <- i
  done

let num w = let s = string_of_int w in String.make (max 0 (11 - String.length s)) ' ' ^ s

let rec read_mouse n =
  if not (changed ()) then begin Proc.sleep Mouse_change; read_mouse n end
  else begin
    qfull := false;
    mousetime := !Dev.seconds ();
    let m = match !queue with m :: rest -> queue := rest; m | [] -> !st in
    let b = buttonmap.(m.buttons land 7) lor (m.buttons land (3 lsl 3)) in
    let b = if !scrollswap then (if b = 8 then 16 else if b = 16 then 8 else b) else b in
    lastcounter := m.counter;
    let r = if !lastresize <> !resize then begin lastresize := !resize; "r" end else "m" in
    let s = r ^ num m.x ^ " " ^ num m.y ^ " " ^ num b ^ " " ^ num m.msec ^ " " in
    String.sub s 0 (min n (String.length s))
  end

let init () =
  Kbd.kbdmouse := (fun b -> kbdbuttons := b; mousetrack 0 0 0 (now_ms ()));
  mousetime := !Dev.seconds ();
  let d = Dev.default 'm' "mouse" in
  let stat c = { (Dev.tab_stat "#m" entries (fun _ -> root) c) with d_atime = !mousetime } in
  Dev.register { d with
    Dev.attach = (fun _ -> Dev.attach 'm' 0 root);
    Dev.walk = Dev.tab_walk entries (fun _ -> root);
    Dev.stat = stat;
    Dev.dirs = (fun c -> List.map (fun e -> { e with d_atime = !mousetime }) (Dev.tab_dirs entries c));
    Dev.open_ = (fun c m ->
      if c.qid.path = qmouse then begin
        if !is_open then raise (Error einuse);
        is_open := true;
        lastresize := !resize
      end;
      Dev.tab_open c m);
    Dev.close = (fun c ->
      if c.qid.path = qmouse then is_open := false);
    Dev.read = (fun c n off ->
      if c.qid.path = qcursor then begin
        if off <> 0 then "" else if n < 72 then raise (Error "i/o count too small") else !cursor
      end
      else if c.qid.path = qmouse then read_mouse (min n 49)
      else "");
    Dev.write = (fun c s _ ->
      let n = String.length s in
      if c.qid.path = qcursor then begin
        cursor := (if n < 72 then bplong (-1) ^ bplong (-1) ^ String.sub arrow 8 64 else String.sub s 0 72);
        min n 72
      end
      else if c.qid.path = qmousectl then begin
        (match List.filter (fun w -> w <> "") (String.split_on_char ' ' (String.map (fun c -> if c = '\n' then ' ' else c) s)) with
         | [ "swap" ] -> setbuttonmap (if !mouseswap then "123" else "321"); mouseswap := not !mouseswap
         | [ "scrollswap" ] -> scrollswap := not !scrollswap
         | [ "buttonmap" ] -> setbuttonmap "123"
         | [ "buttonmap"; m ] -> setbuttonmap m
         | [ "accelerated" ] -> acceleration := 1; maxacc := 2
         | [ "accelerated"; a ] ->
             let a = try int_of_string a with Failure _ -> 1 in
             acceleration := a; maxacc := (if a < 3 then 2 else a)
         | [ "linear" ] -> acceleration := 0
         | _ -> raise (Error "unknown control message"));
        n
      end
      else if c.qid.path = qmousein then begin
        (match numbers (String.sub s 0 (min n 63)) with
         | x :: y :: rest ->
             let b = match rest with b :: _ -> b | [] -> 0 in
             let msec = match rest with _ :: m :: _ when m <> 0 -> m | _ -> now_ms () in
             mousetrack x y b msec
         | _ -> raise (Error "i/o count too small"));
        n
      end
      else if c.qid.path = qmouse then begin
        (match numbers (String.sub s 0 (min n 63)), !screen with
         | x :: y :: _, Some (x0, y0, x1, y1) when x >= x0 && x < x1 && y >= y0 && y < y1 ->
             st := { !st with x = x; y = y; counter = !st.counter + 1 }
         | _ -> ());
        n
      end
      else raise (Error egreg));
  }
