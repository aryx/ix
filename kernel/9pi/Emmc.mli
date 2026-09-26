(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The SD card (principia's emmc.c and sdmmc.c): the BCM2835's Arasan
 * SD host controller (the EMMC, SDHCI's registers) and on it one card,
 * brought online as sdmmc does it (GO_IDLE, SEND_IF_COND, APP_CMD and
 * SD_SEND_OP_COND until powered up, CID, RCA, CSD, SELECT, BLOCKLEN,
 * bus width 4). Blocks read and written by the controller's data port
 * a word at a time, polled (9pi moves them by DMA, waiting for its
 * interrupt: here the kernel simply waits). Registers are read as
 * 16-bit halves (Machine.io_get16: a word is past the Pi1's ints), the
 * card's registers kept as bytes. *)

(* the card: its RCA, its OCR (4 bytes, the lowest first), its CID and
 * CSD (16 bytes), its size *)
type card = {
  rca : int;
  ocr : string;
  cid : string;
  csd : string;
  sectors : int;
  secsize : int;
}

(* the controller reset (emmcinit); its clock and interrupts set
 * (emmcenable) *)
val init : unit -> unit
val enable : unit -> unit

(* "Arasan eMMC SD Host Controller 02 Version 24" (emmcinquiry) *)
val inquiry : unit -> string

(* the card brought online (mmconline); Error on a failed command *)
val online : unit -> card

(* [bio c write buf bno nb]: nb blocks from block bno read (buf "": a
 * string of them) or written (buf's), as mmcbio's multiblock
 * transfers; Error eio *)
val bio : card -> bool -> string -> int -> int -> string

(* the controller's part of the unit's ctl (mmcrctl): "rca ... ocr ...
 * cid ... csd ...\ngeometry ...\n" *)
val rctl : card -> string
