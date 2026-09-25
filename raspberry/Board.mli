(* The Raspberry Pi 1 as QEMU's raspi1ap models it (plan_pi.md, phase
 * A): an ARM1176 (machine/'s Arm32 with its privileged state, Mmu32),
 * 512MB of RAM (the VideoCore's 64MB at the top), and the BCM2835's
 * devices the kernels use: the interrupt controller, the system timer,
 * the PL011, AUX's mini UART, GPIO, the mailbox, the DWC2's registers;
 * the rest of the I/O space reads zero.
 *
 * The loop: before each instruction the IRQ line (when unmasked); the
 * fetch through the MMU into a decode cache by virtual address (and
 * privilege), emptied with the TLB and by I-cache invalidations;
 * aborts, undefined instructions and svc as the architecture's
 * exceptions, DFSR and DFAR, IFSR and IFAR set. Time is counted in
 * instructions: the system timer's microsecond every [ips]. *)

type config = {
  ram_size : int;
  ips : int;                      (* instructions per microsecond *)
  log : string -> unit;           (* what a user may want to know: unassigned I/O, undefined instructions *)
  usb_keyboard : bool;            (* -device usb-kbd *)
  sd : Sdhost.storage option;     (* -drive ...,if=sd *)
  serial0 : char -> unit;         (* the PL011's output (QEMU's first -serial) *)
  serial1 : char -> unit;         (* the mini UART's (the second) *)
  console : int;                  (* the serial the host's input goes to *)
}

type t

val create : config -> t

(* a raw kernel image, as QEMU's -kernel loads it *)
val load_kernel : t -> string -> unit

(* a raw image at an address, the CPU starting there (-device loader,
 * -bios) *)
val load_raw : t -> addr:int -> string -> unit

(* a character typed, for the console's UART *)
val input : t -> char -> unit

(* [batch] instructions, then time and the UART's input *)
val run : t -> batch:int -> unit

(* the screen: width, height, RGB bytes; none before the kernel asked for
 * a framebuffer *)
val screen : t -> (int * int * string) option

(* the framebuffer as the kernel wrote it, for a display *)
val frame : t -> (Framebuffer.geometry * string) option

(* the board's time, microseconds *)
val now : t -> int

(* a key down or up on the USB keyboard (-device usb-kbd), by HID usage *)
val key : t -> int -> bool -> unit

(* keys pressed now and released after [hold] microseconds of the
 * board's time (QMP's send-key) *)
val send_keys : t -> int list -> hold:int -> unit
