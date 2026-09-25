(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See CLI.mli *)

let main (caps : < Cap.argv; Cap.open_in; Cap.open_out; Cap.stdout; Cap.stderr; Cap.fork; Cap.wait; Cap.chdir; Cap.kill; Cap.exec; Cap.env; .. >) =
  match List.tl (Array.to_list (CapSys.argv caps)) with
  | [] -> Console.eprint caps "usage: mini-5i [-t] [-s] program [args...]\n"; 2
  | args ->
      let trace = List.mem "-t" args and stats_on = List.mem "-s" args in
      if List.mem "-y" args then (Linux.log_calls := true; Plan9.log_calls := true);
      let args = List.filter (fun a -> a <> "-t" && a <> "-s" && a <> "-y") args in
      let host = Host.create (caps :> Host.caps) in
      let stats = { Cpu.instructions = 0 } in
      let t0 = Unix.gettimeofday () in
      let report () =
        flush stdout;
        if stats_on then
          let dt = Unix.gettimeofday () -. t0 in
          Console.eprint caps (Printf.sprintf "mini-5i: %d instructions, %.3f s, %.1f MIPS\n" stats.instructions dt
                                 (float stats.instructions /. dt /. 1e6)) in
      let tr = if trace then Some (fun a i -> Console.eprint caps (Printf.sprintf "%8x\t%s\n" a (Arm32.print ~addr:a i))) else None in
      (* a program run; an execve of another restarts here *)
      let rec run prog argv env =
        let file = try Files.read caps (Fpath.v prog) with Sys_error m -> Console.eprint caps ("mini-5i: " ^ m ^ "\n"); exit 127 in
        match (try Some (Elf.parse file) with Elf.Bad _ -> None) with
        | None when Plan9.parse file <> None -> (
            (* a Plan 9 a.out: 5i's personality *)
            let aout = Option.get (Plan9.parse file) in
            let mem = Memory.create () in
            let proc, entry, sp, tos = Plan9.load host mem aout file argv env in
            let st = Arm32.create mem in
            st.r.(13) <- sp;
            st.r.(0) <- tos;
            try Cpu.run32 ?trace:tr st ~pc:entry ~svc:(fun st _ -> Plan9.syscall proc st)
                  ~signal:(fun st pc -> Plan9.deliver proc st ~pc) stats; 0 with
            | Linux.Exit code -> report (); code
            | Linux.Exec (path, argv, env) -> run path argv env
            | Arm32.Unimplemented (w, a) ->
                Console.eprint caps (Printf.sprintf "mini-5i: unimplemented instruction %08x at %x in %s\n" (Bits.unsigned32 w) a prog); report (); 134
            | Memory.Fault a ->
                Console.eprint caps (Printf.sprintf "mini-5i: segmentation fault at %s in %s\n" (Bits.to_hex32 a) prog); report (); 139)
        | Some ({ machine = Arm; _ } as elf) -> (
            let mem = Memory.create () in
            let proc, entry, sp = Linux.load host mem elf file argv env in
            let st = Arm32.create mem in
            st.r.(13) <- sp;
            try Cpu.run32 ?trace:tr st ~pc:entry ~svc:(fun st _ -> Linux.syscall32 proc st)
                  ~signal:(fun st pc -> Linux.deliver proc st ~pc) stats; 0 with
            | Linux.Exit code -> report (); code
            | Linux.Exec (path, argv, env) -> run path argv env
            | Arm32.Unimplemented (w, a) ->
                Console.eprint caps (Printf.sprintf "mini-5i: unimplemented instruction %08x at %x in %s\n" (Bits.unsigned32 w) a prog); report (); 134
            | Memory.Fault a ->
                Console.eprint caps (Printf.sprintf "mini-5i: segmentation fault at %s in %s\n" (Bits.to_hex32 a) prog); report (); 139)
        | Some ({ machine = Aarch64; _ } as elf) -> (
            let mem = Memory.create () in
            let proc, entry, sp = Linux.load host mem elf file argv env in
            let st = Arm64.create mem in
            Arm64.set_sp st Arm64.X 31 (Arm64.of_address sp);
            let tr = if trace then Some (fun a i -> Console.eprint caps (Printf.sprintf "%8x\t%s\n" a (Arm64.print ~addr:a i))) else None in
            try Cpu.run64 ?trace:tr st ~pc:entry ~svc:(fun st _ -> Linux.syscall64 proc st)
                  ~signal:(fun st pc -> Linux.deliver64 proc st ~pc) stats; 0 with
            | Linux.Exit code -> report (); code
            | Linux.Exec (path, argv, env) -> run path argv env
            | Arm64.Unimplemented (w, a) ->
                Console.eprint caps (Printf.sprintf "mini-5i: unimplemented instruction %08x at %x in %s\n" (Bits.unsigned32 w) a prog); report (); 134
            | Memory.Fault a ->
                Console.eprint caps (Printf.sprintf "mini-5i: segmentation fault at %s in %s\n" (Bits.to_hex32 a) prog); report (); 139)
        | _ ->
            (* not an ARM program: the host runs it, as binfmt would *)
            flush_all ();
            (try CapUnix.execve caps prog (Array.of_list argv) (Array.of_list env) with Unix.Unix_error (e, _, _) ->
               Console.eprint caps (Printf.sprintf "mini-5i: %s: %s\n" prog (Unix.error_message e)));
            127 in
      run (List.hd args) args (Array.to_list (Unix.environment ()))
