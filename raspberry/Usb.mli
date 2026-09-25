(* USB devices, as QEMU's (plan_pi.md, phase B): the hub QEMU puts on a
 * one-port controller when a device is attached (hw/usb/dev-hub.c: 8
 * ports, no power switching) and its usb-kbd (hw/usb/dev-hid.c: a
 * full-speed boot keyboard), with their descriptors byte for byte and
 * the requests the kernels send: the standard ones (descriptors,
 * address, configuration, status), the hub's (port status and
 * features: a port reset enables its device), the keyboard's (its
 * report of the keys held, idle, protocol, LEDs). A device's serial
 * number ends with its port path, as QEMU writes it ("68284-1.1").
 *
 * Only endpoint 0's control transfers are modelled: CSUD, the Pi
 * kernels' USB driver, polls the keyboard with GET_REPORT.
 *
 * References: USB 2.0 specification, chapters 9 and 11 (from memory);
 * HID 1.11 (from memory); QEMU's hw/usb/dev-hub.c, dev-hid.c, desc.c
 * (read 2026-09-25). *)

type device

type result = Data of string | Stall | Nak

(* a hub on [path] with devices on its first ports *)
val hub : path:string -> device list -> device

(* a keyboard on [path] *)
val keyboard : path:string -> unit -> device

(* a bus reset: address 0, unconfigured; a hub's ports powered, a
 * device on one connected (a change) *)
val reset : device -> unit

(* the device of an address, under this one through hubs' enabled ports *)
val find : device -> int -> device option

(* endpoint 0's packets: SETUP's 8 bytes, the data stage's IN (up to a
 * length) or OUT, the status stage's empty ones *)
val setup : device -> string -> result
val data_in : device -> int -> result
val data_out : device -> string -> result

(* a key pressed or released on a keyboard, by its HID usage (0x04 a,
 * 0x28 Enter, 0xe0-0xe7 the modifiers) *)
val key : device -> int -> bool -> unit

(* the LEDs the host set (bit 0 Num Lock, 1 Caps Lock, 2 Scroll Lock) *)
val leds : device -> int
