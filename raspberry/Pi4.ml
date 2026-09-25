(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Pi4.mli *)

type config = { ram_size : int; ips : int; log : string -> unit; serial : char -> unit; trace : int; cores : int }

(* a generic timer: CTL (enable 1, mask 2), the compare value *)
type timer = { mutable ctl : int; mutable cval : int64; ppi : int }

(* a core asleep: WFI until an interrupt, WFE until an event too *)
type sleep = Awake | Wfi | Wfe

type core = {
  id : int;
  st : Arm64.state;
  mmu : Mmu64.t;
  virt : timer;
  phys : timer;
  regs : (int, int64) Hashtbl.t;       (* the other system registers, as written *)
  mutable sleep : sleep;
  mutable event : bool;                (* WFE's event register, set by SEV *)
  (* the decode cache: by virtual address, bit 0 set when fetched at
   * EL0 *)
  tags : int array;
  code : Arm64.t array;
}

type t = {
  cores : core array;
  mem : Memory.t;
  gic : Gic.t;
  uart : Pl011.t;
  cfg : config;
  (* the time: the instructions a core has run since the reset (the
   * cores run side by side: a round of turns is one quantum of time),
   * and the counter's ticks skipped while all slept *)
  mutable now : int;
  mutable skipped : int;
  mutable undefined : int list;
  inq : char Queue.t;
}

let cache_bits = 16
let frequency = 62_500_000

(* the cores' turns: a quantum of instructions each, in one thread
 * (plan_pi.md, decision 3) *)
let quantum = 1000

(* the counter: 62.5 ticks a simulated microsecond *)
let count t = Int64.of_int ((t.now * 125 / (2 * t.cfg.ips)) + t.skipped)

(* a timer's condition, and its line to the GIC, the core's own *)
let fired t tm = tm.ctl land 1 <> 0 && Int64.unsigned_compare (count t) tm.cval >= 0
let update_timer t c tm = Gic.set_private t.gic c.id tm.ppi (fired t tm && tm.ctl land 2 = 0)
let update_timers t = Array.iter (fun c -> update_timer t c c.virt; update_timer t c c.phys) t.cores

let flush_code c = Array.fill c.tags 0 (1 lsl cache_bits) (-1)
let flush c = Mmu64.flush c.mmu; flush_code c

(*****************************************************************************)
(* The system registers *)
(*****************************************************************************)

(* QEMU's cortex-a72 (target/arm/tcg/cpu64.c) *)
let midr = 0x410fd083L and ctr = 0x8444c004L and reset_sctlr = 0x00c50838L

let timer_read t tm what =
  match what with
  | "ctl" -> Int64.of_int (tm.ctl lor if fired t tm then 4 else 0)
  | "cval" -> tm.cval
  | _ -> Int64.of_int32 (Int64.to_int32 (Int64.sub tm.cval (count t)))       (* tval: 32 bits, signed *)

let timer_write t c tm what v =
  (match what with
   | "ctl" -> tm.ctl <- Int64.to_int v land 3
   | "cval" -> tm.cval <- v
   | _ -> tm.cval <- Int64.add (count t) (Int64.of_int32 (Int64.to_int32 v)));
  update_timer t c tm

let read_sysreg t c sr =
  match Arm64.sysreg_name sr with
  | "midr_el1" -> midr
  | "mpidr_el1" -> Int64.of_int (0x80000000 lor c.id)       (* core n of a cluster *)
  | "revidr_el1" -> 0L
  | "ctr_el0" -> ctr
  | "dczid_el0" -> 4L                                       (* 64-byte dc zva *)
  | "id_aa64pfr0_el1" -> 0x2222L
  | "id_aa64mmfr0_el1" -> 0x1124L
  | "id_aa64isar0_el1" -> 0x11120L
  | "cntfrq_el0" -> Int64.of_int frequency
  | "cntpct_el0" | "cntvct_el0" -> count t
  | "cntv_ctl_el0" -> timer_read t c.virt "ctl" | "cntv_cval_el0" -> timer_read t c.virt "cval"
  | "cntv_tval_el0" -> timer_read t c.virt "tval"
  | "cntp_ctl_el0" -> timer_read t c.phys "ctl" | "cntp_cval_el0" -> timer_read t c.phys "cval"
  | "cntp_tval_el0" -> timer_read t c.phys "tval"
  | "sctlr_el1" -> c.mmu.sctlr | "tcr_el1" -> c.mmu.tcr | "ttbr0_el1" -> c.mmu.ttbr0 | "ttbr1_el1" -> c.mmu.ttbr1
  | "sctlr_el2" | "sctlr_el3" -> Option.value (Hashtbl.find_opt c.regs sr) ~default:reset_sctlr
  | _ -> Option.value (Hashtbl.find_opt c.regs sr) ~default:0L

let write_sysreg t c sr v =
  match Arm64.sysreg_name sr with
  | "sctlr_el1" -> c.mmu.sctlr <- v; c.st.mmu <- Mmu64.enabled c.mmu; flush c
  | "tcr_el1" -> c.mmu.tcr <- v; flush c
  | "ttbr0_el1" -> c.mmu.ttbr0 <- v; flush c
  | "ttbr1_el1" -> c.mmu.ttbr1 <- v; flush c
  | "cntv_ctl_el0" -> timer_write t c c.virt "ctl" v | "cntv_cval_el0" -> timer_write t c c.virt "cval" v
  | "cntv_tval_el0" -> timer_write t c c.virt "tval" v
  | "cntp_ctl_el0" -> timer_write t c c.phys "ctl" v | "cntp_cval_el0" -> timer_write t c c.phys "cval" v
  | "cntp_tval_el0" -> timer_write t c c.phys "tval" v
  | "midr_el1" | "mpidr_el1" | "revidr_el1" | "ctr_el0" | "dczid_el0" | "cntfrq_el0" | "cntpct_el0" | "cntvct_el0"
  | "id_aa64pfr0_el1" | "id_aa64mmfr0_el1" | "id_aa64isar0_el1" -> raise (Arm64.Unimplemented (0, c.st.next - 4))
  | _ -> Hashtbl.replace c.regs sr v

(* the hints and system operations; hvc and smc undefined (no EL2 or
 * EL3 firmware behind them), brk a debug exception. A TLBI or an IC
 * empties every core's TLB and decode cache, not only the inner
 * shareable ones' (all the cores here): simpler, and never wrong *)
let system t c (st : Arm64.state) (i : Arm64.t) =
  let pc = st.next - 4 in
  match i with
  | Hint Wfi -> c.sleep <- Wfi
  | Hint Wfe -> if c.event then c.event <- false else c.sleep <- Wfe
  | Hint Sev -> Array.iter (fun o -> o.event <- true) t.cores
  | Hint Sevl -> c.event <- true
  | Hint Yield -> ()
  | Sys { op; rt } ->
      (match Arm64.sysop op with
       | "tlbi", _, _ -> Array.iter flush t.cores
       | "ic", _, _ -> Array.iter flush_code t.cores
       | "dc", "zva", _ ->
           let va = Int64.logand (if rt = 31 then 0L else st.x.(rt)) (Int64.lognot 63L) in
           let pa = Arm64.phys st va 1 in
           Memory.write_string t.mem pa (String.make 64 '\000')
       | "dc", _, _ -> ()
       | "at", name, _ ->
           (* PAR: the physical address, or bit 0 and the fault *)
           let user = if String.length name > 3 && name.[3] = '0' then 2 else 0 in
           let write = if name.[String.length name - 1] = 'w' then 1 else 0 in
           let va = if rt = 31 then 0L else st.x.(rt) in
           let par = match Mmu64.translate c.mmu va (user lor write) with
             | pa -> Int64.of_int (pa land lnot 0xfff)
             | exception Arm64.Abort (_, fsc) -> Int64.of_int (1 lor ((fsc land 0x3f) lsl 1)) in
           Hashtbl.replace c.regs (Arm64.sysreg "par_el1") par
       | _ -> raise (Arm64.Unimplemented (0, pc)))
  | Brk imm -> Arm64.take st ~offset:0 ~ret:pc ~esr:(Arm64.syndrome Arm64.ec_brk imm) ()
  | _ -> raise (Arm64.Unimplemented (0, pc))

(*****************************************************************************)
(* The board *)
(*****************************************************************************)

let create (cfg : config) =
  let mem = Memory.create () in
  let gic = Gic.create ~cores:cfg.cores in
  let uart = Pl011.create ~output:cfg.serial ~line:(fun on -> Gic.set gic 153 on) in
  (* the RAM, below the I/O: Bytes.create, not make, so that the host
   * gives its zero pages as they are touched (2GB for QEMU's -m 2G,
   * of which xv6 uses 128MB) *)
  let ram = min cfg.ram_size 0xfc000000 in
  Memory.map_bytes mem ~base:0 "ram" (Bytes.create ram);
  let unassigned = Devices.unassigned ~log:(fun what off -> cfg.log (Printf.sprintf "unassigned %s at 0x%x" what (0xfc000000 + off))) in
  Memory.map_device mem ~base:0xfc000000 ~size:0x4000000 "io" unassigned;
  let dev base size name d = Memory.map_device mem ~base ~size name d in
  dev 0xfe200000 0x100 "gpio" (Devices.regs ());
  dev 0xfe201000 0x1000 "uart0" (Pl011.device uart);
  dev 0xff841000 0x1000 "gicd" (Gic.distributor gic);
  dev 0xff842000 0x2000 "gicc" (Gic.cpu_interface gic);
  let core id =
    let mmu = Mmu64.create mem in
    mmu.sctlr <- reset_sctlr;
    { id; st = Arm64.create mem; mmu; virt = { ctl = 0; cval = 0L; ppi = 27 }; phys = { ctl = 0; cval = 0L; ppi = 30 };
      regs = Hashtbl.create 16; sleep = Awake; event = false;
      tags = Array.make (1 lsl cache_bits) (-1); code = Array.make (1 lsl cache_bits) (Arm64.Undefined 0) } in
  let t = { cores = Array.init cfg.cores core; mem; gic; uart; cfg; now = 0; skipped = 0; undefined = []; inq = Queue.create () } in
  Array.iter (fun c ->
    c.st.read_sysreg <- read_sysreg t c;
    c.st.write_sysreg <- write_sysreg t c;
    c.st.system <- system t c;
    c.st.translate <- Mmu64.translate c.mmu) t.cores;
  t

(* the secondary cores' wait, as the Pi4's firmware parks them and as
 * QEMU does for a Linux kernel (hw/arm/raspi.c's write_smpboot64):
 * polling the spin table at 0xd8 + 8 * core, WFE between two looks,
 * until a kernel writes an address there and SEVs *)
let spin_stub = 0x300
let spin_table = 0xd8
let smpboot = [
  0xd2801b05;          (*        mov     x5, 0xd8 *)
  0xd53800a6;          (*        mrs     x6, mpidr_el1 *)
  0x924004c6;          (*        and     x6, x6, #0x3 *)
  0xd503205f;          (* spin:  wfe *)
  0xf86678a4;          (*        ldr     x4, [x5,x6,lsl #3] *)
  0xb4ffffc4;          (*        cbz     x4, spin *)
  0xd2800000;          (*        mov     x0, #0x0 *)
  0xd2800001;          (*        mov     x1, #0x0 *)
  0xd2800002;          (*        mov     x2, #0x0 *)
  0xd2800003;          (*        mov     x3, #0x0 *)
  0xd61f0080 ]         (*        br      x4 *)

let load_elf t image =
  let elf = Elf.parse image in
  List.iter (fun (s : Elf.segment) -> Memory.write_string t.mem s.paddr (String.sub image s.offset s.filesz)) elf.segments;
  (* the entry, a virtual address, moved as the segment holding it is
   * (hw/core/loader's load_elf) *)
  let entry = match List.find_opt (fun (s : Elf.segment) -> elf.entry >= s.vaddr && elf.entry < s.vaddr + s.filesz) elf.segments with
    | Some s -> elf.entry - s.vaddr + s.paddr
    | None -> elf.entry in
  (* every core at EL3, masked; core 0 at the entry, the others parked
   * (QEMU starts them all at the entry: a race xv6 wins there by
   * timing, not by design, and loses when the cores take turns) *)
  if Array.length t.cores > 1 then begin
    List.iteri (fun i w -> Memory.store32 t.mem (spin_stub + (4 * i)) (Bits.mask32 w)) smpboot;
    for i = 0 to 3 do Memory.store64 t.mem (spin_table + (8 * i)) 0L done
  end;
  Array.iter (fun c ->
    let st = c.st in
    st.el <- 3; st.spsel <- true; st.daif <- 0xf;
    st.next <- if c.id = 0 then entry else spin_stub) t.cores

let input t c = Queue.add c t.inq
let feed t = if Pl011.empty t.uart && not (Queue.is_empty t.inq) then Pl011.input t.uart (Queue.pop t.inq)

let instructions t = t.now

(* an exception from a fault: data or instruction abort, from a lower
 * level or this one *)
let abort (st : Arm64.state) ~pc ~fetch va iss =
  let lower = st.el = 0 in
  let ec = match fetch, lower with
    | true, true -> Arm64.ec_iabort_lower | true, false -> Arm64.ec_iabort
    | false, true -> Arm64.ec_dabort_lower | false, false -> Arm64.ec_dabort in
  Arm64.take st ~offset:0 ~ret:pc ~esr:(Arm64.syndrome ec iss) ~far:va ()

let undefined t c pc w =
  if not (List.mem w t.undefined) then begin
    t.undefined <- w :: t.undefined;
    t.cfg.log (Printf.sprintf "undefined instruction %08x at 0x%Lx (core %d)" w (Arm64.of_pc pc) c.id)
  end;
  Arm64.take c.st ~offset:0 ~ret:pc ~esr:(Arm64.syndrome Arm64.ec_unknown 0) ()

let fetch t c pc user =
  Memory.load32 t.mem (if c.st.mmu && c.st.el < 2 then Mmu64.translate c.mmu (Arm64.of_pc pc) (4 lor user) else pc)

(* a core's turn: up to [n] instructions, until it sleeps *)
let turn t c n =
  let st = c.st in
  let svc st imm = Arm64.take st ~offset:0 ~ret:st.Arm64.next ~esr:(Arm64.syndrome Arm64.ec_svc imm) () in
  let mask = (1 lsl cache_bits) - 1 in
  let k = ref 0 in
  while !k < n && c.sleep = Awake do
    let pc = st.next in
    if st.daif land 2 = 0 && Gic.irq t.gic c.id then Arm64.take st ~offset:0x80 ~ret:pc ()
    else begin
      let user = if st.el = 0 then 2 else 0 in
      let key = pc lor (user lsr 1) in
      let slot = (pc lsr 2) land mask in
      match
        if c.tags.(slot) = key then c.code.(slot)
        else begin
          let i = Arm64.decode (fetch t c pc user) in
          c.tags.(slot) <- key; c.code.(slot) <- i; i
        end
      with
      | exception Arm64.Abort (va, iss) -> abort st ~pc ~fetch:true va iss
      | exception Memory.Fault _ -> abort st ~pc ~fetch:true (Arm64.of_pc pc) 0x10
      | i ->
          let tr = t.cfg.trace in
          if tr <> 0 && (t.now < tr || (tr < 0 && t.now mod (- tr) = 0)) then
            t.cfg.log (Printf.sprintf "%s%Lx el%d %s" (if Array.length t.cores > 1 then Printf.sprintf "[%d] " c.id else "")
                         (Arm64.of_pc pc) st.el (Arm64.print ~addr:pc i));
          (try Arm64.execute st ~addr:pc ~svc i with
           | Arm64.Abort (va, iss) -> abort st ~pc ~fetch:false va iss
           | Memory.Fault a -> abort st ~pc ~fetch:false (Int64.of_int a) 0x10
           | Arm64.Unimplemented (w, _) ->
               let w = if w = 0 then (try fetch t c pc user with _ -> 0) else w in
               undefined t c pc w)
    end;
    t.now <- t.now + 1;
    incr k
  done

(* a core asleep wakes on an interrupt for it, masked or not (WFI), or
 * on an event (WFE) *)
let wake t c =
  match c.sleep with
  | Awake -> ()
  | Wfi -> if Gic.irq t.gic c.id then c.sleep <- Awake
  | Wfe -> if c.event || Gic.irq t.gic c.id then (c.sleep <- Awake; c.event <- false)

(* rounds of turns, [batch] instructions of time; then the timers.
 * With all the cores asleep and nothing pending, the time skips to the
 * next deadline (at most 10ms) *)
let run t ~batch =
  let several = Array.length t.cores > 1 in
  for _ = 1 to max 1 (batch / quantum) do
    let start = t.now in
    Array.iter (fun c ->
      wake t c;
      if c.sleep = Awake then begin
        Gic.set_current t.gic c.id;
        (* the exclusive monitors, cleared at a switch: an ldxr/stxr
         * pair split by it fails and is retried, as it may on hardware
         * (decision 3) *)
        if several then c.st.monitor <- -1;
        t.now <- start;
        turn t c quantum
      end) t.cores;
    t.now <- start + quantum;
    update_timers t
  done;
  if Array.for_all (fun c -> wake t c; c.sleep <> Awake) t.cores then begin
    let until tm =
      if tm.ctl land 3 = 1 then Some (Int64.to_int (Int64.sub tm.cval (count t))) else None in
    let next = List.concat_map (fun c -> List.filter_map until [ c.virt; c.phys ]) (Array.to_list t.cores) in
    let ticks = List.fold_left min (frequency / 100) next in
    t.skipped <- t.skipped + max 1 ticks;
    update_timers t
  end;
  feed t
