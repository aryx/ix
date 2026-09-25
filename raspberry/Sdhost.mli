(* The Arasan SD host controller (the BCM2835's EMMC, base + 0x300000),
 * SDHCI's registers as the Pi names them, and on it QEMU's SD card
 * (hw/sd/sd.c): its CID ("QEMU!", serial 0xdeadbeef) and a standard
 * capacity CSD for the image's size, byte addressed. Commands complete
 * at once (CMDDONE; R1b ones DATADONE too); a read or write of blocks
 * streams through the DATA port a 32-bit word at a time (DMA channel 4
 * moves them, for 9pi), DATADONE at its end. The interrupt (line 62)
 * while INTERRUPT and IRPTEN share a bit.
 *
 * References: SD Host Controller Simplified Specification 3.00 and SD
 * Physical Layer 3.01 (SD Association; from memory); BCM2835 ARM
 * Peripherals, chapter 5 (from memory); 9pi's emmc.c and sdmmc.c;
 * QEMU's hw/sd/sd.c (read 2026-09-25). *)

(* the card's bytes (the -drive image) *)
type storage = { read : int -> int -> string; write : int -> string -> unit; size : int }

type t

val create : card:storage option -> line:(bool -> unit) -> t

val device : t -> Memory.device
