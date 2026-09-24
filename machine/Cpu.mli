(* The loop: fetch, decode (once: a direct-mapped cache of decoded
 * instructions by address, plan_arm.md decision 5), execute. *)

type stats = { mutable instructions : int }

(* runs until the program exits (Linux.Exit), with [trace] called before
 * each instruction, and [signal] between two when Linux.signal_waiting
 * is set (it sets st.next when it enters a handler) *)
val run32 :
  ?trace:(int -> Arm32.t -> unit) -> Arm32.state -> pc:int -> svc:(Arm32.state -> int -> unit) ->
  signal:(Arm32.state -> int -> unit) -> stats -> unit

(* the same for arm64 *)
val run64 :
  ?trace:(int -> Arm64.t -> unit) -> Arm64.state -> pc:int -> svc:(Arm64.state -> int -> unit) ->
  signal:(Arm64.state -> int -> unit) -> stats -> unit
