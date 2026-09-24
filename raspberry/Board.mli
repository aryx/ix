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
}

type t

(* the board, its UART's output to [output] *)
val create : config -> output:(char -> unit) -> t

(* a raw kernel image, as QEMU's -kernel loads it *)
val load_kernel : t -> string -> unit

(* a character typed, for the UART *)
val input : t -> char -> unit

(* [batch] instructions, then time and the UART's input *)
val run : t -> batch:int -> unit
