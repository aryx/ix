(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Emmc.mli *)

open Types

let eio = "i/o error"

(*****************************************************************************)
(* The controller (emmc.c) *)
(*****************************************************************************)

(* its registers: offsets from the peripherals' base *)
let base = 0x300000
let blksizecnt = 0x04 and arg1 = 0x08 and cmdtm = 0x0c and resp0 = 0x10 and data = 0x20
and status = 0x24 and control0 = 0x28 and control1 = 0x2c and interrupt = 0x30 and irptmask = 0x34
and irpten = 0x38 and slotisrver = 0xfc

let lo r = Machine.io_get16 (base + r) false
let hi r = Machine.io_get16 (base + r) true
(* a word written: its halves (v in the Pi1's ints, a negative one's bit
 * 31 set: a mask's lnot) *)
let wr r v = Machine.io_set32 (base + r) ((v asr 16) land 0xffff) (v land 0xffff)

(* Control1's bits *)
let srstdata = 1 lsl 26 and srstcmd = 1 lsl 25 and srsthc = 1 lsl 24 and datatoshift = 16
and clken = 1 lsl 2 and clkintlen = 1
(* Interrupt's (the low half's; the errors' from 16: the high half) *)
let cmddone = 1 and datadone = 2 and err = 1 lsl 15
(* Status's *)
let cmdinhibit = 1 and datinhibit = 2 and bufwrite = 1 lsl 10 and bufread = 1 lsl 11

(* Cmdtm's fields *)
let ixchken = 1 lsl 20 and crcchken = 1 lsl 19 and isdata = 1 lsl 21
let respnone = 0 and resp136 = 1 lsl 16 and resp48 = 2 lsl 16 and resp48busy = 3 lsl 16
let multiblock = 1 lsl 5 and card2host = 1 lsl 4 and blkcnten = 1 lsl 1

(* cmdinfo: each command's response and data *)
let cmdinfo cmd =
  let crc = ixchken lor crcchken in
  match cmd with
  | 0 -> ixchken
  | 2 | 9 -> resp136
  | 3 | 6 | 8 | 13 | 55 -> resp48 lor crc
  | 7 | 12 -> resp48busy lor crc
  | 16 | 41 -> resp48
  | 17 -> resp48 lor isdata lor card2host lor crc
  | 18 -> resp48 lor isdata lor card2host lor multiblock lor blkcnten lor crc
  | 24 -> resp48 lor isdata lor crc
  | 25 -> resp48 lor isdata lor multiblock lor blkcnten lor crc
  | _ -> raise (Error eio)

(* polled until [f ()] (a bound: the C's one-second timeout) *)
let poll f = let rec go n = if f () then true else if n = 0 then false else go (n - 1) in go 1000000

let extclk = 50000000
let initfreq = 400000
let sdfreq = 25000000
let dto = 14

(* the clock's divider in Control1's fields *)
let clkdiv d = ((d lsl 8) land 0xff00) lor (((d lsr 8) lsl 6) land 0xc0)

let init () =
  (* emmcinit's message (the clock's rate from the firmware: 50MHz) *)
  Devcons.print (Printf.sprintf "eMMC external clock %d Mhz\n" (extclk / 1000000));
  wr control1 srsthc;
  ignore (poll (fun () -> hi control1 land (srsthc lsr 16) = 0))

let clock freq =
  wr control1 (clkdiv ((extclk / freq) - 1) lor (dto lsl datatoshift) lor clken lor clkintlen);
  if not (poll (fun () -> lo control1 land 2 <> 0)) then Devcons.print "SD clock won't initialise!\n"

let enable () =
  clock initfreq;
  (* all but Dtoerr and Cardintr *)
  wr irptmask (lnot ((1 lsl 20) lor (1 lsl 8)))

let inquiry () =
  let ver = hi slotisrver in
  Printf.sprintf "Arasan eMMC SD Host Controller %02x Version %02x" (ver land 0xff) (ver lsr 8)

(* a register's 4 bytes, the lowest first *)
let bytes r =
  let l = lo r and h = hi r in
  let b = String.make 4 '\000' in
  String.set b 0 (Char.chr (l land 0xff)); String.set b 1 (Char.chr (l lsr 8));
  String.set b 2 (Char.chr (h land 0xff)); String.set b 3 (Char.chr (h lsr 8));
  b

(* Interrupt cleared of what is set (its halves) *)
let clear_interrupt mask_lo =
  let l = lo interrupt land mask_lo and h = hi interrupt in
  if l <> 0 || h <> 0 then Machine.io_set32 (base + interrupt) h l

(* a command (emmccmd): its response, as bytes (R2's 16: the 128 bits
 * shifted by 8, as the controller drops the CRC; R1's 4) *)
let rec cmd c arg = cmd2 c ((arg asr 16) land 0xffff) (arg land 0xffff)

(* a command whose argument is an RCA (its high half: rca lsl 16 is past
 * the Pi1's ints) *)
and cmd_rca c rca = cmd2 c rca 0

and cmd2 c arg_hi arg_lo =
  let info = cmdinfo c in
  let command = (c lsl 24) lor info in
  if lo status land cmdinhibit <> 0 then begin
    Machine.io_set32 (base + control1) (hi control1 lor (srstcmd lsr 16)) (lo control1);
    ignore (poll (fun () -> hi control1 land (srstcmd lsr 16) = 0))
  end;
  if lo status land datinhibit <> 0 && (info land isdata <> 0 || info land resp48busy = resp48busy) then begin
    Machine.io_set32 (base + control1) (hi control1 lor (srstdata lsr 16)) (lo control1);
    ignore (poll (fun () -> hi control1 land (srstdata lsr 16) = 0))
  end;
  Machine.io_set32 (base + arg1) arg_hi arg_lo;
  clear_interrupt 0xffff;
  wr cmdtm command;
  ignore (poll (fun () -> lo interrupt land (cmddone lor err) <> 0));
  let i = lo interrupt in
  if i land (cmddone lor err) <> cmddone then begin
    (* all but a timeout said (9pi's) *)
    if not (i land err <> 0 && hi interrupt = 1) then
      Devcons.print (Printf.sprintf "emmc: cmd %x error intr %x stat %x\n" command ((hi interrupt lsl 16) lor i)
                       ((hi status lsl 16) lor lo status));
    clear_interrupt 0xffff;
    raise (Error eio)
  end;
  (* the done bit cleared, not the data's *)
  clear_interrupt (lnot (datadone lor (1 lsl 5) lor (1 lsl 4)) land 0xffff);
  let resp =
    if info land resp48busy = resp136 then
      "\000" ^ String.sub (bytes resp0 ^ bytes (resp0 + 4) ^ bytes (resp0 + 8) ^ bytes (resp0 + 12)) 0 15
    else if info land resp48busy = respnone then "\000\000\000\000"
    else bytes resp0 in
  if info land resp48busy = resp48busy then begin
    if not (poll (fun () -> lo interrupt land (datadone lor err) <> 0)) then
      Devcons.print (Printf.sprintf "emmcio: no Datadone after CMD%d\n" c);
    clear_interrupt 0xffff
  end;
  if c = 7 then clock sdfreq;
  if c = 6 then wr control0 (if arg_lo = 2 then lo control0 lor 2 else lo control0 land lnot 2);
  resp

(*****************************************************************************)
(* The card (sdmmc.c) *)
(*****************************************************************************)

type card = { rca : int; ocr : string; cid : string; csd : string; sectors : int; secsize : int }

(* rbits: [len] bits of a register's bytes from bit [start] *)
let rbits b start len =
  let v = ref 0 in
  for i = len - 1 downto 0 do
    let bit = start + i in
    v := (!v lsl 1) lor ((Char.code b.[bit / 8] lsr (bit mod 8)) land 1)
  done;
  !v

let csdbits csd hi_ lo_ = rbits csd lo_ (hi_ - lo_ + 1)

(* the geometry from the CSD (identify) *)
let identify csd =
  let secsize = 1 lsl csdbits csd 83 80 in
  let sectors =
    match csdbits csd 127 126 with
    | 0 -> (csdbits csd 73 62 + 1) * (1 lsl (csdbits csd 49 47 + 2))
    | _ -> (csdbits csd 69 48 + 1) * (512 * 1024 / secsize) in
  if secsize = 1024 then sectors * 2, 512 else sectors, secsize

let voltage = 1 lsl 8 and checkpattern = 0x42 and hcs = 1 lsl 30 and v3_3 = 3 lsl 20

let online () =
  ignore (cmd 0 0);
  let hcs =
    try
      let r = cmd 8 (voltage lor checkpattern) in
      if Char.code r.[0] = checkpattern && Char.code r.[1] = 1 && r.[2] = '\000' && r.[3] = '\000' then hcs else 0
    with Error _ -> 0 in
  let rec power i =
    if i = 15 then begin Devcons.print "sdmmc: card won't power up\n"; raise (Error eio) end;
    ignore (cmd 55 0);
    let r = cmd 41 (hcs lor v3_3) in
    if Char.code r.[3] land 0x80 <> 0 then r else power (i + 1) in
  let ocr = power 0 in
  let cid = cmd 2 0 in
  let r = cmd 3 0 in
  let rca = Char.code r.[2] lor (Char.code r.[3] lsl 8) in
  let csd = cmd_rca 9 rca in
  let sectors, secsize = identify csd in
  ignore (cmd_rca 7 rca);
  ignore (cmd 16 secsize);
  ignore (cmd_rca 55 rca);
  ignore (cmd 6 2);
  { rca = rca; ocr = ocr; cid = cid; csd = csd; sectors = sectors; secsize = secsize }

(* the card's address of a block: its byte offset, but an SDHC's (Ccs) *)
let address c b = if Char.code c.ocr.[3] land 0x40 <> 0 then b else b * c.secsize

let bio c write buf bno nb =
  let len = c.secsize in
  wr blksizecnt ((nb lsl 16) lor len);
  let r = Buffer.create (if write then 0 else nb * len) in
  (try
    ignore (cmd (if write then 25 else 18) (address c bno));
    for k = 0 to nb - 1 do
      if not (poll (fun () -> lo status land (if write then bufwrite else bufread) <> 0)) then raise (Error eio);
      if write then Machine.io_write_fifo (base + data) (String.sub buf (k * len) len)
      else Buffer.add_string r (Machine.io_read_fifo (base + data) len)
    done;
    if not (poll (fun () -> lo interrupt land (datadone lor err) <> 0)) then raise (Error eio);
    if lo interrupt land err <> 0 then begin clear_interrupt 0xffff; raise (Error eio) end;
    clear_interrupt 0xffff
  with e -> (try ignore (cmd 12 0) with Error _ -> ()); raise e);
  ignore (cmd 12 0);
  Buffer.contents r

(* %8.8ux of a register's bytes, the highest first *)
let hex b =
  let s = ref "" in
  for i = 0 to String.length b - 1 do s := Printf.sprintf "%02x" (Char.code b.[i]) ^ !s done;
  !s

let rctl c =
  Printf.sprintf "rca %04x ocr %s\ncid %s csd %s\ngeometry %d %d\n" c.rca (hex c.ocr) (hex c.cid) (hex c.csd)
    c.sectors c.secsize
