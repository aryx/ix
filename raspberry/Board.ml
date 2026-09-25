(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Board.mli *)

type config = {
  ram_size : int; ips : int; log : string -> unit; usb_devices : string list;   (* -device's USB ones, in order: "usb-kbd", "usb-mouse" *)
  sd : Sdhost.storage option;
  serial0 : char -> unit;            (* the PL011 *)
  serial1 : char -> unit;            (* the mini UART *)
  console : int;                     (* the serial the host's input goes to *)
}

(* the ARM1176's CP15 registers other than the MMU's *)
type cp15 = {
  mutable actlr : int;
  mutable cpacr : int;
  mutable dfsr : int;
  mutable ifsr : int;
  mutable dfar : int;
  mutable ifar : int;
  mutable fcse : int;
  mutable contextid : int;
  tpid : int array;
}

type t = {
  st : Arm32.state;
  mem : Memory.t;
  mmu : Mmu32.t;
  cp : cp15;
  intc : Intc.t;
  timer : Systimer.t;
  uart : Pl011.t;
  mini : Miniuart.t;
  mutable wfi : bool;               (* a WFI: time may jump to the next event *)
  cfg : config;
  (* the decode cache: by virtual address, bit 0 set when fetched in
   * user mode; emptied with the TLB and by I-cache invalidations *)
  tags : int array;
  code : Arm32.t array;
  mutable instructions : int;
  mutable time_left : int;          (* instructions not yet a microsecond *)
  mutable undefined : int list;     (* the words already reported *)
  inq : char Queue.t;               (* the host's characters, for the UART *)
  fb : Framebuffer.t;
  keyboard : Usb.device option;
  mouse : Usb.device option;
  mutable key_events : (int * int * bool) list;   (* at a microsecond: a usage, down *)
}

let cache_bits = 16
let io = 0x20000000

let flush t = Mmu32.flush t.mmu; Array.fill t.tags 0 (1 lsl cache_bits) (-1)

(*****************************************************************************)
(* CP15 *)
(*****************************************************************************)

(* the ARM1176JZF-S's identification, as QEMU's arm1176 *)
let midr = 0x410fb767 and ctr = 0x1dd20d2

let set_sctlr t v =
  t.mmu.sctlr <- v;
  t.st.mmu <- v land 1 <> 0;
  t.st.vectors <- (if v land (1 lsl 13) <> 0 then Bits.mask32 (0xffff lsl 16) else 0);
  flush t

let mrc t ~crn ~crm ~opc2 =
  let c = t.cp and m = t.mmu in
  match crn, crm, opc2 with
  | 0, 0, 0 -> midr | 0, 0, 1 -> ctr
  (* the feature registers, as QEMU's arm1176 (9pi reads ID_PFR1 and
   * ID_MMFR3) *)
  | 0, 1, k -> [| 0x111; 0x11; 0x33; 0; 0x01130003; 0x10030302; 0x01222100; 0 |].(k)
  | 0, 2, k when k <= 5 -> [| 0x0140011; 0x12002111; 0x11231111; 0x01102131; 0x141; 0 |].(k)
  | 1, 0, 0 -> m.sctlr | 1, 0, 1 -> c.actlr | 1, 0, 2 -> c.cpacr
  | 2, 0, 0 -> m.ttbr0 | 2, 0, 1 -> m.ttbr1 | 2, 0, 2 -> m.ttbcr
  | 3, 0, 0 -> m.dacr
  | 5, 0, 0 -> c.dfsr | 5, 0, 1 -> c.ifsr
  | 6, 0, 0 -> c.dfar | 6, 0, 2 -> c.ifar
  | 13, 0, 0 -> c.fcse | 13, 0, 1 -> c.contextid | 13, 0, k when k >= 2 && k <= 4 -> c.tpid.(k - 2)
  | _ -> 0

let mcr t ~crn ~crm ~opc2 v =
  let c = t.cp and m = t.mmu in
  match crn, crm, opc2 with
  | 1, 0, 0 -> set_sctlr t v
  | 1, 0, 1 -> c.actlr <- v
  | 1, 0, 2 ->
      (* only cp10 and cp11's access is kept, the rest reading as QEMU
       * gives it (0xC0F00000 after 9pi's 0x0FFFFFFF); VFP granted with
       * both full *)
      c.cpacr <- (v land 0x00f00000) lor 0xc0000000;
      t.st.vfp_ok <- c.cpacr land 0x00f00000 = 0x00f00000
  | 2, 0, 0 -> m.ttbr0 <- v; flush t | 2, 0, 1 -> m.ttbr1 <- v; flush t | 2, 0, 2 -> m.ttbcr <- v; flush t
  | 3, 0, 0 -> m.dacr <- v; flush t
  | 5, 0, 0 -> c.dfsr <- v | 5, 0, 1 -> c.ifsr <- v
  | 6, 0, 0 -> c.dfar <- v | 6, 0, 2 -> c.ifar <- v
  (* the caches: only an instruction cache's invalidation matters, the
   * decode cache's; the TLB's *)
  | 7, (5 | 7), 0 -> Array.fill t.tags 0 (1 lsl cache_bits) (-1)
  | 7, 0, 4 -> t.wfi <- true                              (* wait for interrupt *)
  | 8, _, _ -> flush t
  | 13, 0, 0 -> c.fcse <- v | 13, 0, 1 -> c.contextid <- v | 13, 0, k when k >= 2 && k <= 4 -> c.tpid.(k - 2) <- v
  | _ -> ()                                              (* cache and write-buffer operations, c15's *)

(* mcr, mrc, mcrr, the hints *)
let coproc t (st : Arm32.state) (i : Arm32.t) =
  match i with
  | Coproc { cp = 15; opc1 = 0; load = true; crn; crm; opc2; rd; _ } ->
      let v = mrc t ~crn ~crm ~opc2 in
      if rd = 15 then Arm32.write_cpsr st v 8 else st.r.(rd) <- v
  | Coproc { cp = 15; opc1 = 0; load = false; crn; crm; opc2; rd; _ } -> mcr t ~crn ~crm ~opc2 st.r.(rd)
  | Coproc2 { cp = 15; load = false; _ } -> ()            (* the ARM1176's cache range operations *)
  | Hint { hint = 3; _ } -> t.wfi <- true
  | Hint _ -> ()
  | _ -> raise (Arm32.Unimplemented (0, st.r.(15) - 8))

(*****************************************************************************)
(* The board *)
(*****************************************************************************)

(* the VideoCore's share, at the top of RAM: QEMU's raspi1ap gives it
 * 64MB of 512 *)
let vc_size = 64 * 1024 * 1024

let create cfg =
  let mem = Memory.create () in
  let st = Arm32.create mem in
  let mmu = Mmu32.create mem in
  let fb = Framebuffer.create mem in
  let intc = Intc.create () in
  let timer = Systimer.create ~line:(fun n on -> Intc.set intc n on) in
  let uart = Pl011.create ~output:cfg.serial0 ~line:(fun on -> Intc.set intc 57 on) in
  let mini = Miniuart.create ~output:cfg.serial1 ~line:(fun on -> Intc.set intc 29 on) in
  Memory.map_bytes mem ~base:0 "ram" (Bytes.make cfg.ram_size '\000');
  (* the I/O space, where no device answers: zero, and a note *)
  let unassigned = Devices.unassigned ~log:(fun what off -> cfg.log (Printf.sprintf "unassigned %s at 0x%x" what (io + off))) in
  Memory.map_device mem ~base:io ~size:0x1000000 "io" unassigned;
  Memory.map_device mem ~base:0x40000000 ~size:0x40000000 "gpu" unassigned;
  let dev base size name d = Memory.map_device mem ~base:(io + base) ~size name d in
  dev 0x3000 0x1c "systimer" (Systimer.device timer);
  dev 0xb200 0x28 "intc" (Intc.device intc);
  dev 0xb880 0x40 "mailbox" (Devices.mailbox ~mem ~ram_size:cfg.ram_size ~vc_base:(cfg.ram_size - vc_size) ~board_rev:0x900021 ~on_framebuffer:(Framebuffer.configure fb));
  dev 0x200000 0xb4 "gpio" (Devices.regs ());
  dev 0x201000 0x1000 "uart0" (Pl011.device uart);
  dev 0x215000 0x100 "aux" (Miniuart.device mini);
  dev 0x300000 0x100 "emmc" (Sdhost.device (Sdhost.create ~card:cfg.sd ~line:(fun on -> Intc.set intc 62 on)));
  dev 0x7000 0x1000 "dma" (Dma.device (Dma.create ~mem ~line:(fun n on -> Intc.set intc n on)));
  (* the USB devices: behind the hub QEMU adds on the controller's one
   * port, on its ports in their order (1.1, 1.2, ...) *)
  let devices = List.mapi (fun i name ->
    let path = Printf.sprintf "1.%d" (i + 1) in
    name, (if name = "usb-mouse" then Usb.mouse ~path () else Usb.keyboard ~path ())) cfg.usb_devices in
  let keyboard = List.assoc_opt "usb-kbd" devices and mouse = List.assoc_opt "usb-mouse" devices in
  let root = if devices = [] then None else Some (Usb.hub ~path:"1" (List.map snd devices)) in
  dev 0x980000 0x10000 "usb" (Dwc2.device (Dwc2.create ~mem ~root ~line:(fun on -> Intc.set intc 9 on) ~now:(fun () -> Systimer.now timer)));
  let cp = { actlr = 0; cpacr = 0; dfsr = 0; ifsr = 0; dfar = 0; ifar = 0; fcse = 0; contextid = 0; tpid = Array.make 3 0 } in
  let t = { st; mem; mmu; cp; intc; timer; uart; mini; wfi = false; cfg;
            tags = Array.make (1 lsl cache_bits) (-1); code = Array.make (1 lsl cache_bits) (Arm32.Undefined 0);
            instructions = 0; time_left = 0; undefined = []; inq = Queue.create (); fb; keyboard; mouse; key_events = [] } in
  st.coproc <- coproc t;
  st.translate <- (fun va access -> Mmu32.translate mmu ~user:(st.mode = 0x10) va access);
  set_sctlr t 0x00050078;
  t

(* as QEMU's arm boot loads a raw kernel: at 0x10000, with ATAGs at
 * 0x100 (the core, the memory), and the CPU in SVC with A, I and F
 * masked, r1 the machine (0xc42, BCM2708), r2 the ATAGs *)
let load_kernel t image =
  Memory.write_string t.mem 0x10000 image;
  let words = [ 5; 0x54410001; 1; 4096; 0;  4; 0x54410002; t.cfg.ram_size; 0;  0; 0 ] in
  List.iteri (fun i w -> Memory.store32 t.mem (0x100 + (4 * i)) w) words;
  let st = t.st in
  Arm32.set_mode st 0x13;
  st.a_off <- true; st.i_off <- true; st.f_off <- true;
  st.r.(0) <- 0; st.r.(1) <- 0xc42; st.r.(2) <- 0x100;
  st.next <- 0x10000

(* a character from the host, when the UART can take it (one at a time:
 * the kernels run it with its FIFO off) *)
let input t c = Queue.add c t.inq

(* the console's UART takes the host's characters as it has room *)
let feed t =
  if t.cfg.console = 1 then (while Miniuart.room t.mini && not (Queue.is_empty t.inq) do Miniuart.input t.mini (Queue.pop t.inq) done)
  else if Pl011.empty t.uart && not (Queue.is_empty t.inq) then Pl011.input t.uart (Queue.pop t.inq)

(* a raw image at an address, the CPU there in its reset state (QEMU's
 * -device loader with cpu-num, -bios) *)
let load_raw t ~addr image =
  Memory.write_string t.mem addr image;
  let st = t.st in
  Arm32.set_mode st 0x13;
  st.a_off <- true; st.i_off <- true; st.f_off <- true;
  st.next <- addr

let screen t = Framebuffer.rgb t.fb
let frame t = Framebuffer.raw t.fb

let now t = Systimer.now t.timer

(* a key now (the window's) *)
let key t usage down = Option.iter (fun k -> Usb.key k usage down) t.keyboard

(* the mouse's input now (QMP's input-send-event) *)
let pointer t inputs = Option.iter (fun m -> Usb.pointer m inputs) t.mouse

(* keys pressed now and released after [hold] microseconds of the
 * board's time, as QEMU's send-key (its hold-time: 100ms) *)
let send_keys t usages ~hold =
  List.iter (fun u -> key t u true) usages;
  t.key_events <- t.key_events @ List.map (fun u -> now t + hold, u, false) usages

let timed_keys t =
  let due, later = List.partition (fun (at, _, _) -> at <= now t) t.key_events in
  t.key_events <- later;
  List.iter (fun (_, u, down) -> key t u down) due

(* the instructions of a batch, then time: the system timer advances a
 * microsecond per [ips] instructions (plan_pi.md, decision 6) *)
let run t ~batch =
  let st = t.st in
  let svc st _ = Arm32.take st Arm32.Supervisor_call ~ret:(st.Arm32.r.(15) - 4) in
  let mask = (1 lsl cache_bits) - 1 in
  (* claude: a WFI ends the batch where it is (the core waits there):
   * the time skipped at the WFI, not later in the batch between two
   * instructions -- mini-xv6's tick read the counter, the batch went
   * on to its end, 10ms were skipped there, and the compare it then
   * wrote was already past: no tick ever again *)
  let executed = ref 0 in
  while !executed < batch && not t.wfi do
    incr executed;
    let pc = st.next in
    if (not st.f_off) && Intc.fiq t.intc then Arm32.take st Arm32.Fiq ~ret:(pc + 4)
    else if (not st.i_off) && Intc.irq t.intc then Arm32.take st Arm32.Irq ~ret:(pc + 4)
    else begin
      let key = pc lor (if st.mode = 0x10 then 1 else 0) in
      let slot = (pc lsr 2) land mask in
      match
        if t.tags.(slot) = key then t.code.(slot)
        else begin
          let pa = if st.mmu then Mmu32.translate t.mmu ~user:(st.mode = 0x10) pc 0 else pc in
          let i = Arm32.decode (Memory.load32 t.mem pa) in
          t.tags.(slot) <- key; t.code.(slot) <- i; i
        end
      with
      | exception Arm32.Abort (va, fsr) ->
          t.cp.ifar <- va; t.cp.ifsr <- fsr land 0x40f;
          Arm32.take st Arm32.Prefetch_abort ~ret:(pc + 4)
      | i ->
          (try Arm32.execute st ~addr:pc ~svc i with
           | Arm32.Abort (va, fsr) ->
               t.cp.dfar <- va; t.cp.dfsr <- fsr;
               Arm32.take st Arm32.Data_abort ~ret:(pc + 8)
           | Arm32.Unimplemented (w, _) ->
               let w = if w = 0 then Memory.load32 t.mem (if st.mmu then Mmu32.translate t.mmu ~user:false pc 0 else pc) else w in
               if not (List.mem w t.undefined) then begin
                 t.undefined <- w :: t.undefined;
                 t.cfg.log (Printf.sprintf "undefined instruction %08x at 0x%x" w pc)
               end;
               Arm32.take st Arm32.Undefined_instruction ~ret:(pc + 4))
    end
  done;
  (* a WFI with nothing pending: the time to the next compare skipped
   * (at most 10ms, the idle loop checking again) *)
  if t.wfi then begin
    t.wfi <- false;
    if not (Intc.irq t.intc || Intc.fiq t.intc) then Systimer.advance t.timer (min 10000 (max 1 (Systimer.until_next t.timer)))
  end;
  let batch = !executed in
  t.instructions <- t.instructions + batch;
  let ticks = t.time_left + batch in
  Systimer.advance t.timer (ticks / t.cfg.ips);
  t.time_left <- ticks mod t.cfg.ips;
  if t.key_events <> [] then timed_keys t;
  feed t
