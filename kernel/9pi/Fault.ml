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

let create kind base top image fstart flen =
  { kind = kind; base = base; top = top; image = image; fstart = fstart; flen = flen;
    pages = Hashtbl.create 16; sref = 1 }

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

let map pgdir pg pa = if not (Mmu.map pgdir pg pa) then raise (Error enovmem)

(* a page of s made: zeroed, or read from the image; recorded, mapped *)
let make pgdir s pg =
  (* the image read first: a read may sleep, another sharer make it *)
  let data = match s.image with
    | Some c when pg - s.base < s.flen -> Some (read_image c (s.fstart + pg - s.base) (min pgsize (s.flen - (pg - s.base))))
    | _ -> None in
  if not (Hashtbl.mem s.pages pg) then begin
    let pa = match Mmu.kalloc () with Some pa -> pa | None -> raise (Error enovmem) in
    (match data with Some d -> Machine.Phys.write pa d | None -> ());
    Hashtbl.add s.pages pg pa
  end;
  map pgdir pg (Hashtbl.find s.pages pg)

let fill pgdir s pg =
  try map pgdir pg (Hashtbl.find s.pages pg) with Not_found -> make pgdir s pg

let fault (p : proc) va =
  match segment p va with
  | None -> false
  | Some s ->
      let pg = va land lnot (pgsize - 1) in
      (* a mapped page's fault is its rights': not resolved here *)
      if Mmu.mapped p.pgdir pg then false else begin fill p.pgdir s pg; true end

let validaddr (p : proc) addr len =
  let rec go pg =
    if pg < addr + len then begin
      (match segment p pg with
       | Some s -> if not (Mmu.mapped p.pgdir pg) then fill p.pgdir s pg
       | None -> ());
      go (pg + pgsize)
    end in
  if len > 0 then go (addr land lnot (pgsize - 1))

let page pgdir s va = fill pgdir s (va land lnot (pgsize - 1))

let dup s pgdir share =
  if share then begin
    s.sref <- s.sref + 1;
    Hashtbl.iter (fun pg pa -> map pgdir pg pa) s.pages;
    s
  end else begin
    (match s.image with Some c -> Chan.incref c | None -> ());
    let n = create s.kind s.base s.top s.image s.fstart s.flen in
    Hashtbl.iter (fun pg pa ->
      let npa = match Mmu.kalloc () with Some x -> x | None -> raise (Error enovmem) in
      Machine.Phys.copy npa pa pgsize;
      Hashtbl.add n.pages pg npa;
      map pgdir pg npa) s.pages;
    n
  end

let release pgdir segs =
  List.iter (fun s ->
    s.sref <- s.sref - 1;
    if s.sref = 0 then begin
      Hashtbl.iter (fun _ pa -> Mmu.kfree pa) s.pages;
      Hashtbl.clear s.pages;
      match s.image with Some c -> Chan.close c | None -> ()
    end) segs;
  if pgdir <> 0 then Mmu.free_tables pgdir

let shrink (p : proc) s newtop =
  if s.sref > 1 then raise (Error einuse);
  let gone = ref [] in
  Hashtbl.iter (fun pg pa -> if pg >= newtop then gone := (pg, pa) :: !gone) s.pages;
  List.iter (fun (pg, pa) -> Hashtbl.remove s.pages pg; Mmu.unmap p.pgdir pg; Mmu.kfree pa) !gone;
  (* the TLB flushed *)
  Machine.mmu_switch p.pgdir
