(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Syscall.mli *)

open Types

let errmax = 128
let maxpath = 1024
let bit16sz = 2

type call =
  | Nop | Rfork | Exec | Exits | Await | Brk | Open | Close | Dup | Fd2path | Pread | Pwrite | Seek
  | Create | Remove | Chdir | Stat | Fstat | Wstat | Fwstat | Bind | Mount | Unmount | Sleep | Alarm
  | Notify | Noted | Pipe | Segattach | Segdetach | Segfree | Segflush | Segbrk
  | Rendezvous | Semacquire | Semrelease | Tsemacquire | Fversion | Fauth | Errstr

(* by number, as sys.h has them; their names as /proc/n/status shows
 * them (sysctab) *)
let calls = [|
  Nop, "Nop"; Rfork, "Rfork"; Exec, "Exec"; Exits, "Exits"; Await, "Await"; Brk, "Brk";
  Open, "Open"; Close, "Close"; Dup, "Dup"; Fd2path, "Fd2path"; Pread, "Pread"; Pwrite, "Pwrite";
  Seek, "Seek"; Create, "Create"; Remove, "Remove"; Chdir, "Chdir"; Stat, "Stat"; Fstat, "Fstat";
  Wstat, "Wstat"; Fwstat, "Fwstat"; Bind, "Bind"; Mount, "Mount"; Unmount, "Unmount";
  Sleep, "Sleep"; Alarm, "Alarm"; Notify, "Notify"; Noted, "Noted"; Pipe, "Pipe";
  Segattach, "Segattach"; Segdetach, "Segdetach"; Segfree, "Segfree"; Segflush, "Segflush";
  Segbrk, "Segbrk"; Rendezvous, "Rendez"; Semacquire, "Semacquire"; Semrelease, "Semrelease";
  Tsemacquire, "Tsemacquire"; Fversion, "Fversion"; Fauth, "Fauth"; Errstr, "Errstr" |]

(*****************************************************************************)
(* The user's memory *)
(*****************************************************************************)

(* a user's bytes, their pages faulted in first (validaddr) *)
let user_string (p : proc) addr max =
  Fault.validaddr p addr max;
  match Mmu.read_string p.pgdir addr max with Some s -> s | None -> raise (Error ebadarg)

let user_read (p : proc) addr n =
  Fault.validaddr p addr n;
  match Mmu.read p.pgdir addr n with Some s -> s | None -> raise (Error ebadarg)

let user_write (p : proc) addr s =
  Fault.validaddr p addr (String.length s);
  if not (Mmu.copyout p.pgdir addr s) then raise (Error ebadarg)

(* snprint into the user's buffer: at most n-1 bytes and a NUL; how
 * many *)
let user_snprint (p : proc) addr n s =
  let s = if String.length s >= n then String.sub s 0 (max 0 (n - 1)) else s in
  if n > 0 then user_write p addr (s ^ "\000");
  String.length s

(* a vlong argument (two words, the low first): None for -1 (the
 * channel's own offset); offsets past 1GB are not the Pi1's ints *)
let offset lo hi =
  if lo = -1 && hi = -1 then None
  else if hi < 0 then raise (Error enegoff)
  else if hi > 0 || lo < 0 then raise (Error ebadarg)
  else Some lo

(* %q: quoted as rc would read it, when it needs to be *)
let quote s =
  let needs = s = "" || (let r = ref false in
                         for i = 0 to String.length s - 1 do
                           if (try ignore (String.index " \t\n'`^#*[]=|&;()<>{}$\"" s.[i]); true with Not_found -> false)
                           then r := true
                         done; !r) in
  if not needs then s
  else begin
    let b = Buffer.create (String.length s + 2) in
    Buffer.add_char b '\'';
    for i = 0 to String.length s - 1 do
      if s.[i] = '\'' then Buffer.add_char b '\'';
      Buffer.add_char b s.[i]
    done;
    Buffer.add_char b '\'';
    Buffer.contents b
  end

(*****************************************************************************)
(* Processes *)
(*****************************************************************************)

let find_proc pid = List.find (fun o -> match o with Some q -> q.pid = pid && q.state <> Zombie | None -> false)
                      (Array.to_list Proc.procs)

let exits (p : proc) status =
  Chan.fgrp_close p.fgrp;
  if p.pid = 1 then ignore (Machine.panic ("boot process died: " ^ (if status = "" then "unknown" else status)));
  (* the parent told, if still there (the last child's first) *)
  (if p.parent <> 0 then
     match (try find_proc p.parent with Not_found -> None) with
     | Some q ->
         q.nchild <- q.nchild - 1;
         if List.length q.waitq < 128 then begin
           let msg = if status = "" then "" else p.text ^ " " ^ string_of_int p.pid ^ ": " ^ status in
           let msg = if String.length msg >= errmax then String.sub msg 0 (errmax - 1) else msg in
           q.waitq <- { wpid = p.pid; wtime = (!Proc.ticks - p.start) * 10; wmsg = msg } :: q.waitq;
           Proc.wakeup (Child_exit q.pid)
         end
     | None -> ());
  Machine.mmu_switch 0;
  if p.pgdir <> 0 then Mmu.free p.pgdir;
  p.pgdir <- 0;
  Fault.release p.segs;
  p.segs <- [];
  p.state <- Zombie;
  Proc.sched ()

(* pprint: a message on the process's standard error, "text pid: "
 * first (devcons_pprint) *)
let pprint (p : proc) s =
  match p.fgrp.fds.(2) with
  | Some c when (match c.opened with Some m -> m.access = Owrite || m.access = Ordwr | None -> false) ->
      (try ignore ((Dev.find c.dev).Dev.write c (p.text ^ " " ^ string_of_int p.pid ^ ": " ^ s) c.offset)
       with Error _ -> ())
  | _ -> ()

(* a note the process cannot take (none handled yet, notify's handlers
 * not called: stage B's rest): its end, as notify's without a handler *)
let suicide (p : proc) msg =
  pprint p ("suicide: " ^ msg ^ "\n");
  exits p msg

let rfnameg = 1 and rfenvg = 2 and rffdg = 4 and rfnoteg = 8 and rfproc = 16 and rfmem = 32 and rfnowait = 64
and rfcnameg = 1024 and rfcenvg = 2048 and rfcfdg = 4096 and rfrend = 8192 and rfnomnt = 16384

let noteids = ref 1

(* the groups a process gets, from its own and the flags *)
let groups (p : proc) flag =
  let fg = if flag land rffdg <> 0 then Chan.fgrp_copy p.fgrp
    else if flag land rfcfdg <> 0 then Chan.fgrp_new ()
    else begin p.fgrp.fref <- p.fgrp.fref + 1; p.fgrp end in
  let pg = if flag land rfnameg <> 0 then Chan.pgrp_copy p.pgrp
    else if flag land rfcnameg <> 0 then { mnt = [] } else p.pgrp in
  let eg = if flag land rfenvg <> 0 then Devenv.copy p.egrp
    else if flag land rfcenvg <> 0 then { vars = []; last_path = 0 } else p.egrp in
  fg, pg, eg

let rfork (p : proc) flag =
  if flag land (rffdg lor rfcfdg) = rffdg lor rfcfdg || flag land (rfnameg lor rfcnameg) = rfnameg lor rfcnameg
     || flag land (rfenvg lor rfcenvg) = rfenvg lor rfcenvg then raise (Error ebadarg);
  if flag land rfproc = 0 then begin
    if flag land (rfmem lor rfnowait) <> 0 then raise (Error ebadarg);
    let old = p.fgrp in
    let fg, pg, eg = groups p flag in
    if fg != old then Chan.fgrp_close old else old.fref <- old.fref - 1;
    p.fgrp <- fg; p.pgrp <- pg; p.egrp <- eg;
    if flag land rfnoteg <> 0 then begin incr noteids; p.noteid <- !noteids end;
    0
  end else begin
    if flag land rfmem <> 0 then raise (Error "rfork RFMEM: not yet");
    let slot = match Proc.free_slot () with Some s -> s | None -> raise (Error "no free processes") in
    let pgdir = match Mmu.create () with Some d -> d | None -> raise (Error enovmem) in
    if not (List.for_all (fun s -> Mmu.copy_range p.pgdir pgdir s.base s.top) p.segs) then begin
      Mmu.free pgdir; raise (Error enovmem)
    end;
    let fg, pg, eg = groups p flag in
    let pid = !Proc.nextpid in
    incr Proc.nextpid;
    if flag land rfnoteg <> 0 then incr noteids;
    let child = {
      pid = pid; slot = slot; state = Runnable;
      parent = (if flag land rfnowait <> 0 then 0 else p.pid); nchild = 0; waitq = [];
      pgdir = pgdir;
      segs = List.map (fun s -> (match s.image with Some c -> Chan.incref c | None -> ()); { s with top = s.top }) p.segs;
      fgrp = fg; pgrp = pg; egrp = eg; slash = p.slash; dot = p.dot;
      notify = p.notify; noteid = (if flag land rfnoteg <> 0 then !noteids else p.noteid);
      errstr = ""; text = p.text; start = !Proc.ticks; psstate = ""; args = p.args; killed = false } in
    if flag land rfnowait = 0 then p.nchild <- p.nchild + 1;
    ignore (Mmu.write pgdir (Exec.ustktop - Exec.tos_size + 52) (Machine.le32 pid));
    Machine.tf_copy slot;
    Machine.proc_context slot;
    Proc.procs.(slot) <- Some child;
    Proc.ready child;
    Proc.yield ();
    pid
  end

let await (p : proc) buf n =
  if p.nchild = 0 && p.waitq = [] then raise (Error enochild);
  let rec wait () = match p.waitq with
    | [] -> Proc.sleep (Child_exit p.pid); wait ()
    | w :: rest -> p.waitq <- rest; w in
  let w = wait () in
  user_snprint p buf n (Printf.sprintf "%d %d %d %d %s" w.wpid 0 0 w.wtime (quote w.wmsg))

let sleep_ms (p : proc) ms =
  if ms <= 0 then Proc.yield ()
  else begin
    let until = !Proc.ticks + ((ms + 9) / 10) in
    while !Proc.ticks < until && not p.killed do Proc.sleep Ticks done
  end;
  0

(*****************************************************************************)
(* Memory *)
(*****************************************************************************)

let seg (p : proc) kind =
  try List.find (fun s -> s.kind = kind) p.segs with Not_found -> raise (Error ebadarg)

(* ibrk on the bss: its top moved to addr (0: where it starts) *)
let brk (p : proc) addr =
  let s = seg p Bss in
  if addr = 0 then s.base
  else begin
    let addr =
      if addr >= s.base then addr
      else if addr < (seg p Data).base then raise (Error enovmem)
      else s.base in
    (* the new pages given at their first touch (Fault) *)
    let newtop = Mmu.pgroundup addr in
    if newtop < s.top then begin
      ignore (Mmu.dealloc p.pgdir s.top newtop);
      s.top <- newtop
    end else begin
      List.iter (fun ns -> if ns != s && newtop >= ns.base && newtop < ns.top then raise (Error esoverlap)) p.segs;
      s.top <- newtop
    end;
    0
  end

(*****************************************************************************)
(* Files *)
(*****************************************************************************)

let sysopen (p : proc) name m =
  let c = Chan.open_ (Chan.namec p name) (Chan.mode_of_int m) in
  try Chan.fdalloc p c with e -> Chan.close c; raise e

let syscreate (p : proc) name m perm =
  let c = Chan.create p name (Chan.mode_of_int (m land lnot 0x1000)) perm in
  try Chan.fdalloc p c with e -> Chan.close c; raise e

let sysclose (p : proc) fd =
  let c = Chan.fdtochan p fd None in
  p.fgrp.fds.(fd) <- None;
  Chan.close c;
  0

let pread (p : proc) fd buf n off =
  if n < 0 then raise (Error ebadarg);
  let c = Chan.fdtochan p fd (Some Oread) in
  if c.qid.typ = Qt_dir then begin
    (match off with Some o when o <> c.offset -> raise (Error edirseek) | _ -> ());
    let s, k = Dev.dirread (Chan.dirs c) c.dri n in
    user_write p buf s;
    c.dri <- c.dri + k;
    c.offset <- c.offset + String.length s;
    String.length s
  end else begin
    let s = (Dev.find c.dev).Dev.read c n (match off with Some o -> o | None -> c.offset) in
    user_write p buf s;
    if off = None then c.offset <- c.offset + String.length s;
    String.length s
  end

let pwrite (p : proc) fd buf n off =
  if n < 0 then raise (Error ebadarg);
  let s = user_read p buf n in
  let c = Chan.fdtochan p fd (Some Owrite) in
  if c.qid.typ = Qt_dir then raise (Error eisdir);
  let m = (Dev.find c.dev).Dev.write c s (match off with Some o -> o | None -> c.offset) in
  if off = None then c.offset <- c.offset + m;
  m

(* seek: the new offset written at the vlong the first argument points
 * to (5c's vlong results) *)
let seek (p : proc) ret fd lo hi typ =
  let c = Chan.fdtochan p fd None in
  if c.dev = '|' then raise (Error eisstream);
  let o = if hi = -1 && lo < 0 then lo else match offset lo hi with Some o -> o | None -> -1 in
  let off =
    match typ with
    | 0 -> if c.qid.typ = Qt_dir && o <> 0 then raise (Error eisdir); o
    | 1 -> if c.qid.typ = Qt_dir then raise (Error eisdir); c.offset + o
    | 2 -> if c.qid.typ = Qt_dir then raise (Error eisdir); ((Dev.find c.dev).Dev.stat c).d_length + o
    | _ -> raise (Error ebadarg) in
  if off < 0 then raise (Error enegoff);
  c.offset <- off;
  c.dri <- 0;
  user_write p ret (Machine.le32 off ^ Machine.le32 0);
  0

let dup (p : proc) fd nfd =
  let c = Chan.fdtochan p fd None in
  Chan.incref c;
  if nfd = -1 then (try Chan.fdalloc p c with e -> Chan.close c; raise e)
  else begin Chan.fdalloc_at p nfd c; nfd end

(* one attach (a new pipe), its two ends walked from it *)
let pipe (p : proc) addr =
  let d = Chan.namec p "#|" in
  let dev = Dev.find d.dev in
  let end_ name = let c = Chan.clone d in c.qid <- dev.Dev.walk d c name; c.cname <- "#|/" ^ name; c in
  let c0 = Chan.open_ (end_ "data") (Chan.mode_of_int 2) in
  let c1 = Chan.open_ (end_ "data1") (Chan.mode_of_int 2) in
  let fd0 = Chan.fdalloc p c0 in
  let fd1 = try Chan.fdalloc p c1 with e -> p.fgrp.fds.(fd0) <- None; Chan.close c0; Chan.close c1; raise e in
  user_write p addr (Machine.le32 fd0 ^ Machine.le32 fd1);
  0

(* a stat's entry named by the path's last element (dirsetname), into
 * the user's buffer: all of it, or its size alone when it does not fit *)
let stat_out (p : proc) (c : chan) buf n =
  if n < bit16sz then raise (Error eshortstat);
  let d = (Dev.find c.dev).Dev.stat c in
  let name = if c.cname = "/" then "/" else Chan.basename c.cname in
  let e = Dev.encode { d with d_name = name } in
  if String.length e > n then begin user_write p buf (String.sub e 0 bit16sz); bit16sz end
  else begin user_write p buf e; String.length e end

let wstat (p : proc) (c : chan) buf n =
  let d = Dev.decode (user_read p buf n) in
  (Dev.find c.dev).Dev.wstat c d;
  n

let chdir (p : proc) name =
  let c = Chan.namec p name in
  if c.qid.typ <> Qt_dir then raise (Error enotdir);
  p.dot <- c;
  0

let remove (p : proc) name =
  let c = Chan.namec_nomount p name in
  (Dev.find c.dev).Dev.remove c;
  0

(*****************************************************************************)
(* The namespace *)
(*****************************************************************************)

let bind (p : proc) newname oldname flag =
  if flag land lnot 7 <> 0 || flag land 3 = 3 then raise (Error ebadarg);
  let newc = Chan.namec p newname in
  let old = Chan.namec_nomount p oldname in
  Chan.bind p.pgrp newc old flag;
  0

(* mount (bindmount): the server on fd attached (devmnt), its root bound
 * at old; MCACHE (0x10) accepted, no cache here *)
let mount (p : proc) fd oldname flag aname =
  if flag land lnot 0x17 <> 0 || flag land 3 = 3 then raise (Error ebadarg);
  let c = Chan.fdtochan p fd (Some Ordwr) in
  let root = Devmnt.attach c aname in
  let old = Chan.namec_nomount p oldname in
  root.cname <- old.cname;
  Chan.bind p.pgrp root old (flag land 7);
  root.devno

let fauth (p : proc) fd aname =
  let c = Chan.fdtochan p fd (Some Ordwr) in
  let ac = Devmnt.auth c aname in
  ac.opened <- Some { (Chan.mode_of_int 2) with cexec = true };
  Chan.fdalloc p ac

let unmount (p : proc) newaddr oldname =
  let old = Chan.namec_nomount p oldname in
  let newc = if newaddr = 0 then None else Some (Chan.namec p (user_string p newaddr maxpath)) in
  Chan.unmount p.pgrp newc old;
  0

(*****************************************************************************)
(* errstr *)
(*****************************************************************************)

let errstr (p : proc) buf n =
  if n <= 0 then raise (Error ebadarg);
  let n = min n errmax in
  let mine = user_read p buf n in
  let mine = try String.sub mine 0 (String.index mine '\000') with Not_found -> String.sub mine 0 (n - 1) in
  let e = if String.length p.errstr >= n then String.sub p.errstr 0 (n - 1) else p.errstr in
  user_write p buf (e ^ "\000");
  p.errstr <- mine;
  0

(*****************************************************************************)
(* The dispatch *)
(*****************************************************************************)

(* argv: the user's array of strings, to its 0 *)
let user_args (p : proc) addr =
  let rec go a acc =
    let v = Arch.get_word (user_read p a 4) 0 in
    if v = 0 then List.rev acc else go (a + 4) (user_string p v maxpath :: acc) in
  go addr []

(* a permission argument: its rwx bits, DMDIR (bit 31, past the Pi1's
 * ints) as the int's sign (P9.perm) *)
let perm_arg words i =
  let b k = Char.code words.[(4 * i) + k] in
  (b 0 lor (b 1 lsl 8) lor (b 2 lsl 16) lor ((b 3 land 0x3f) lsl 24)) lor (if b 3 land 0x80 <> 0 then min_int else 0)

let call (p : proc) c a words =
  let str i = user_string p a.(i) maxpath in
  match c with
  | Nop -> 0
  | Rfork -> rfork p a.(0)
  | Exec ->
      let name = str 0 in
      let r = Exec.exec p name (user_args p a.(1)) in
      Exec.set_tos_pid p;
      r
  | Exits -> exits p (if a.(0) = 0 then "" else user_string p a.(0) errmax); 0
  | Await -> await p a.(0) a.(1)
  | Brk -> brk p a.(0)
  | Open -> sysopen p (str 0) a.(1)
  | Close -> sysclose p a.(0)
  | Dup -> dup p a.(0) a.(1)
  | Fd2path -> ignore (user_snprint p a.(1) a.(2) (Chan.fdtochan p a.(0) None).cname); 0
  | Pread -> pread p a.(0) a.(1) a.(2) (offset a.(3) a.(4))
  | Pwrite -> pwrite p a.(0) a.(1) a.(2) (offset a.(3) a.(4))
  | Seek -> seek p a.(0) a.(1) a.(2) a.(3) a.(4)
  | Create -> syscreate p (str 0) a.(1) (perm_arg words 2)
  | Remove -> remove p (str 0)
  | Chdir -> chdir p (str 0)
  | Stat ->
      let ch = Chan.namec p (str 0) in
      let r = try stat_out p ch a.(1) a.(2) with e -> Chan.clunk ch; raise e in
      Chan.clunk ch;
      r
  | Fstat -> stat_out p (Chan.fdtochan p a.(0) None) a.(1) a.(2)
  | Wstat -> wstat p (Chan.namec_nomount p (str 0)) a.(1) a.(2)
  | Fwstat -> wstat p (Chan.fdtochan p a.(0) None) a.(1) a.(2)
  | Bind -> bind p (str 0) (str 1) a.(2)
  | Unmount -> unmount p a.(0) (str 1)
  | Mount -> mount p a.(0) (str 2) a.(3) (if a.(4) = 0 then "" else str 4)
  | Fauth -> fauth p a.(0) (if a.(1) = 0 then "" else str 1)
  | Fversion ->
      let v = user_read p a.(2) a.(3) in
      if a.(3) = 0 || (try ignore (String.index v '\000'); false with Not_found -> true) then raise (Error ebadarg);
      Devmnt.version (Chan.fdtochan p a.(0) (Some Ordwr)) a.(1) v
  | Sleep -> sleep_ms p a.(0)
  | Alarm -> 0
  | Notify -> p.notify <- a.(0); 0
  | Noted -> 0
  | Pipe -> pipe p a.(0)
  | Errstr -> errstr p a.(0) a.(1)
  | _ -> raise (Error "not yet")

(* a trace of the calls on the console (Main's [trace]): a debugging
 * aid, off *)
let trace = ref false

let syscall (p : proc) =
  let nr = Machine.tf_get Arch.tf_syscall in
  let ret =
    try
      if nr < 0 || nr >= Array.length calls then raise (Error ebadarg);
      let c, name = calls.(nr) in
      let sp = Machine.tf_get Arch.tf_sp in
      let words = user_read p (sp + 4) 20 in
      let a = Array.init 5 (fun i -> Arch.get_word words (4 * i)) in
      p.psstate <- name;
      let traced = !trace in
      if traced then Devcons.print (Printf.sprintf "[%d %s %x %x %x]" p.pid name a.(0) a.(1) a.(2));
      let r =
        try call p c a words
        with Error "not yet" as e -> Devcons.print ("mini-9pi: " ^ String.lowercase name ^ ": not yet\n"); raise e in
      p.psstate <- "";
      if traced then Devcons.print (Printf.sprintf "[%d = %d]\n" p.pid r);
      r
    with Error e ->
      if !trace && nr = 2 then Devcons.print (Printf.sprintf "[%d error %s]\n" p.pid e);
      p.psstate <- "";
      p.errstr <- (if String.length e >= errmax then String.sub e 0 (errmax - 1) else e);
      -1 in
  Machine.tf_set 0 ret
