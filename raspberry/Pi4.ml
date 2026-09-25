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

type config = { ram_size : int; ips : int; log : string -> unit; serial : char -> unit; trace : int }

(* a generic timer: CTL (enable 1, mask 2), the compare value *)
type timer = { mutable ctl : int; mutable cval : int64; ppi : int }

type t = {
  st : Arm64.state;
  mem : Memory.t;
  mmu : Mmu64.t;
  gic : Gic.t;
  uart : Pl011.t;
  virt : timer;
  phys : timer;
  regs : (int, int64) Hashtbl.t;       (* the other system registers, as written *)
  mutable wfi : bool;
  cfg : config;
  tags : int array;
  code : Arm64.t array;
  mutable instructions : int;
  mutable skipped : int;               (* the counter's ticks a WFI skipped *)
  mutable undefined : int list;
  inq : char Queue.t;
}

let cache_bits = 16
let frequency = 62_500_000

(* the counter: 62.5 ticks a simulated microsecond *)
let count t = Int64.of_int ((t.instructions * 125 / (2 * t.cfg.ips)) + t.skipped)

(* a timer's condition, and its line to the GIC *)
let fired t tm = tm.ctl land 1 <> 0 && Int64.unsigned_compare (count t) tm.cval >= 0
let update_timer t tm = Gic.set t.gic tm.ppi (fired t tm && tm.ctl land 2 = 0)
let update_timers t = update_timer t t.virt; update_timer t t.phys

let flush_code t = Array.fill t.tags 0 (1 lsl cache_bits) (-1)
let flush t = Mmu64.flush t.mmu; flush_code t

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

let timer_write t tm what v =
  (match what with
   | "ctl" -> tm.ctl <- Int64.to_int v land 3
   | "cval" -> tm.cval <- v
   | _ -> tm.cval <- Int64.add (count t) (Int64.of_int32 (Int64.to_int32 v)));
  update_timer t tm

let read_sysreg t sr =
  match Arm64.sysreg_name sr with
  | "midr_el1" -> midr
  | "mpidr_el1" -> 0x80000000L                              (* core 0, of a cluster *)
  | "revidr_el1" -> 0L
  | "ctr_el0" -> ctr
  | "dczid_el0" -> 4L                                       (* 64-byte dc zva *)
  | "id_aa64pfr0_el1" -> 0x2222L
  | "id_aa64mmfr0_el1" -> 0x1124L
  | "id_aa64isar0_el1" -> 0x11120L
  | "cntfrq_el0" -> Int64.of_int frequency
  | "cntpct_el0" | "cntvct_el0" -> count t
  | "cntv_ctl_el0" -> timer_read t t.virt "ctl" | "cntv_cval_el0" -> timer_read t t.virt "cval"
  | "cntv_tval_el0" -> timer_read t t.virt "tval"
  | "cntp_ctl_el0" -> timer_read t t.phys "ctl" | "cntp_cval_el0" -> timer_read t t.phys "cval"
  | "cntp_tval_el0" -> timer_read t t.phys "tval"
  | "sctlr_el1" -> t.mmu.sctlr | "tcr_el1" -> t.mmu.tcr | "ttbr0_el1" -> t.mmu.ttbr0 | "ttbr1_el1" -> t.mmu.ttbr1
  | "sctlr_el2" | "sctlr_el3" -> Option.value (Hashtbl.find_opt t.regs sr) ~default:reset_sctlr
  | _ -> Option.value (Hashtbl.find_opt t.regs sr) ~default:0L

let write_sysreg t sr v =
  match Arm64.sysreg_name sr with
  | "sctlr_el1" -> t.mmu.sctlr <- v; t.st.mmu <- Mmu64.enabled t.mmu; flush t
  | "tcr_el1" -> t.mmu.tcr <- v; flush t
  | "ttbr0_el1" -> t.mmu.ttbr0 <- v; flush t
  | "ttbr1_el1" -> t.mmu.ttbr1 <- v; flush t
  | "cntv_ctl_el0" -> timer_write t t.virt "ctl" v | "cntv_cval_el0" -> timer_write t t.virt "cval" v
  | "cntv_tval_el0" -> timer_write t t.virt "tval" v
  | "cntp_ctl_el0" -> timer_write t t.phys "ctl" v | "cntp_cval_el0" -> timer_write t t.phys "cval" v
  | "cntp_tval_el0" -> timer_write t t.phys "tval" v
  | "midr_el1" | "mpidr_el1" | "revidr_el1" | "ctr_el0" | "dczid_el0" | "cntfrq_el0" | "cntpct_el0" | "cntvct_el0"
  | "id_aa64pfr0_el1" | "id_aa64mmfr0_el1" | "id_aa64isar0_el1" -> raise (Arm64.Unimplemented (0, t.st.next - 4))
  | _ -> Hashtbl.replace t.regs sr v

(* the hints and system operations; hvc and smc undefined (no EL2 or
 * EL3 firmware behind them), brk a debug exception *)
let system t (st : Arm64.state) (i : Arm64.t) =
  let pc = st.next - 4 in
  match i with
  | Hint (Wfi | Wfe) -> t.wfi <- true
  | Hint _ -> ()
  | Sys { op; rt } ->
      (match Arm64.sysop op with
       | "tlbi", _, _ -> flush t
       | "ic", _, _ -> flush_code t
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
           let par = match Mmu64.translate t.mmu va (user lor write) with
             | pa -> Int64.of_int (pa land lnot 0xfff)
             | exception Arm64.Abort (_, fsc) -> Int64.of_int (1 lor ((fsc land 0x3f) lsl 1)) in
           Hashtbl.replace t.regs (Arm64.sysreg "par_el1") par
       | _ -> raise (Arm64.Unimplemented (0, pc)))
  | Brk imm -> Arm64.take st ~offset:0 ~ret:pc ~esr:(Arm64.syndrome Arm64.ec_brk imm) ()
  | _ -> raise (Arm64.Unimplemented (0, pc))

(*****************************************************************************)
(* The board *)
(*****************************************************************************)

let create cfg =
  let mem = Memory.create () in
  let st = Arm64.create mem in
  let mmu = Mmu64.create mem in
  let gic = Gic.create () in
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
  let t = { st; mem; mmu; gic; uart; virt = { ctl = 0; cval = 0L; ppi = 27 }; phys = { ctl = 0; cval = 0L; ppi = 30 };
            regs = Hashtbl.create 16; wfi = false; cfg;
            tags = Array.make (1 lsl cache_bits) (-1); code = Array.make (1 lsl cache_bits) (Arm64.Undefined 0);
            instructions = 0; skipped = 0; undefined = []; inq = Queue.create () } in
  mmu.sctlr <- reset_sctlr;
  st.read_sysreg <- read_sysreg t;
  st.write_sysreg <- write_sysreg t;
  st.system <- system t;
  st.translate <- Mmu64.translate mmu;
  t

let load_elf t image =
  let elf = Elf.parse image in
  List.iter (fun (s : Elf.segment) -> Memory.write_string t.mem s.paddr (String.sub image s.offset s.filesz)) elf.segments;
  (* the entry, a virtual address, moved as the segment holding it is
   * (hw/core/loader's load_elf) *)
  let entry = match List.find_opt (fun (s : Elf.segment) -> elf.entry >= s.vaddr && elf.entry < s.vaddr + s.filesz) elf.segments with
    | Some s -> elf.entry - s.vaddr + s.paddr
    | None -> elf.entry in
  let st = t.st in
  st.el <- 3; st.spsel <- true; st.daif <- 0xf;
  st.next <- entry

let input t c = Queue.add c t.inq
let feed t = if Pl011.empty t.uart && not (Queue.is_empty t.inq) then Pl011.input t.uart (Queue.pop t.inq)

let instructions t = t.instructions

(* an exception from a fault: data or instruction abort, from a lower
 * level or this one *)
let abort (st : Arm64.state) ~pc ~fetch va iss =
  let lower = st.el = 0 in
  let ec = match fetch, lower with
    | true, true -> Arm64.ec_iabort_lower | true, false -> Arm64.ec_iabort
    | false, true -> Arm64.ec_dabort_lower | false, false -> Arm64.ec_dabort in
  Arm64.take st ~offset:0 ~ret:pc ~esr:(Arm64.syndrome ec iss) ~far:va ()

let undefined t pc w =
  if not (List.mem w t.undefined) then begin
    t.undefined <- w :: t.undefined;
    t.cfg.log (Printf.sprintf "undefined instruction %08x at 0x%Lx" w (Arm64.of_pc pc))
  end;
  Arm64.take t.st ~offset:0 ~ret:pc ~esr:(Arm64.syndrome Arm64.ec_unknown 0) ()

let fetch t pc user = Memory.load32 t.mem (if t.st.mmu && t.st.el < 2 then Mmu64.translate t.mmu (Arm64.of_pc pc) (4 lor user) else pc)

let run t ~batch =
  let st = t.st in
  let svc st imm = Arm64.take st ~offset:0 ~ret:st.Arm64.next ~esr:(Arm64.syndrome Arm64.ec_svc imm) () in
  let mask = (1 lsl cache_bits) - 1 in
  for _ = 1 to batch do
    let pc = st.next in
    if st.daif land 2 = 0 && Gic.irq t.gic then Arm64.take st ~offset:0x80 ~ret:pc ()
    else begin
      let user = if st.el = 0 then 2 else 0 in
      let key = pc lor (user lsr 1) in
      let slot = (pc lsr 2) land mask in
      match
        if t.tags.(slot) = key then t.code.(slot)
        else begin
          let i = Arm64.decode (fetch t pc user) in
          t.tags.(slot) <- key; t.code.(slot) <- i; i
        end
      with
      | exception Arm64.Abort (va, iss) -> abort st ~pc ~fetch:true va iss
      | exception Memory.Fault _ -> abort st ~pc ~fetch:true (Arm64.of_pc pc) 0x10
      | i ->
          let n = t.cfg.trace in
          if n <> 0 && (t.instructions < n || (n < 0 && t.instructions mod (- n) = 0)) then
            t.cfg.log (Printf.sprintf "%Lx el%d %s" (Arm64.of_pc pc) st.el (Arm64.print ~addr:pc i));
          (try Arm64.execute st ~addr:pc ~svc i with
           | Arm64.Abort (va, iss) -> abort st ~pc ~fetch:false va iss
           | Memory.Fault a -> abort st ~pc ~fetch:false (Int64.of_int a) 0x10
           | Arm64.Unimplemented (w, _) ->
               let w = if w = 0 then (try fetch t pc user with _ -> 0) else w in
               undefined t pc w)
    end;
    t.instructions <- t.instructions + 1
  done;
  update_timers t;
  (* a WFI with nothing pending: the time to the next deadline skipped *)
  if t.wfi then begin
    t.wfi <- false;
    if not (Gic.irq t.gic) then begin
      let until tm =
        if tm.ctl land 3 = 1 then Some (Int64.to_int (Int64.sub tm.cval (count t))) else None in
      let next = List.filter_map until [ t.virt; t.phys ] in
      let ticks = List.fold_left min (frequency / 100) next in
      t.skipped <- t.skipped + max 1 ticks;
      update_timers t
    end
  end;
  feed t
