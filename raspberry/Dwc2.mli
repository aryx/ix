(* The DWC2 USB host controller (base + 0x980000), as QEMU's raspi
 * models it (hw/usb/hcd-dwc2.c): QEMU's id (2.94a, the kernels'
 * "emulating" test) and reset values, resets that finish at once; the
 * root port's HPRT (a reset ends by enabling the port and resetting
 * its device); and the host channels: a transfer runs whole when its
 * channel is enabled, by DMA, then HCTSIZ holds what is left and HCINT
 * says complete and halted -- no ACK, and a zero-length transfer's
 * packet count unchanged, as QEMU (CSUD knows both quirks). Only
 * control transfers are modelled (CSUD makes no other). *)

type t

(* the controller, a device (QEMU's hub, and on it a keyboard) on its
 * root port or none *)
(* [now]: the board's time, in microseconds *)
val create : mem:Memory.t -> root:Usb.device option -> line:(bool -> unit) -> now:(unit -> int) -> t

val device : t -> Memory.device
