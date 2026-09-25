(* mini-xv6's USB (as xv6 arm-pi1's CSUD finds its keyboard, simpler): the
 * DWC2 controller (usb.c's two primitives, both boards), the hub on its
 * root port (QEMU puts one there), and behind the hub the HID devices in
 * their boot protocol -- a keyboard, a mouse. Everything is polled: the
 * transfers to their end, and the devices' interrupt endpoints at each
 * tick (a NAK: nothing new). The keyboard's keys pressed are the
 * console's input, as the UART's characters are (File.intr: US keys,
 * Shift, Control); the mouse moves the screen's cursor (Screen). *)

(* the controller started, the devices found (none: nothing) *)
val init : unit -> unit

(* the devices' reports read, the keys and moves handled *)
val poll : unit -> unit
