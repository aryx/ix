(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Fault.mli *)

open Types

let pgsize = Mmu.pgsize

let segment (p : proc) va = try Some (List.find (fun s -> va >= s.base && va < s.top) p.segs) with Not_found -> None

(* all of [n] bytes at [off] (fewer: the file's end) *)
let read_image c off n =
  let d = Dev.find c.dev in
  let b = Buffer.create n in
  let rec go () =
    if Buffer.length b < n then begin
      let s = d.Dev.read c (n - Buffer.length b) (off + Buffer.length b) in
      if s <> "" then begin Buffer.add_string b s; go () end
    end in
  go ();
  Buffer.contents b

let fill (p : proc) s pg =
  (match Mmu.alloc p.pgdir pg (pg + pgsize) with Some _ -> () | None -> raise (Error enovmem));
  match s.image with
  | Some c ->
      let off = pg - s.base in
      if off < s.flen then ignore (Mmu.write p.pgdir pg (read_image c (s.fstart + off) (min pgsize (s.flen - off))))
  | None -> ()

let fault (p : proc) va =
  match segment p va with
  | None -> false
  | Some s ->
      let pg = va land lnot (pgsize - 1) in
      (* a mapped page's fault is its rights': not resolved here *)
      if Mmu.mapped p.pgdir pg then false else begin fill p s pg; true end

let validaddr (p : proc) addr len =
  let rec go pg =
    if pg < addr + len then begin
      (match segment p pg with
       | Some s -> if not (Mmu.mapped p.pgdir pg) then fill p s pg
       | None -> ());
      go (pg + pgsize)
    end in
  if len > 0 then go (addr land lnot (pgsize - 1))

let release segs = List.iter (fun s -> match s.image with Some c -> Chan.close c | None -> ()) segs
