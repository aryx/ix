(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Pager.mli *)

type t = { fd : Unix.file_descr; mutable n_pages : int; mutable page_size : int }
type page = { npage : int; data : Bytes.t }

exception Bad_page of int

let open_file (_ : < Cap.open_in; Cap.open_out; .. >) (file : Fpath.t) =
  { fd = Unix.openfile (Fpath.to_string file) [ Unix.O_RDWR; Unix.O_CREAT ] 0o666; n_pages = 0; page_size = 0 }

let set_page_size t size =
  t.page_size <- size;
  t.n_pages <- (Unix.fstat t.fd).st_size / size

let page_size t = t.page_size

(* as many bytes as the file has, up to [len], from [off] *)
let read_at t off (b : Bytes.t) len =
  ignore (Unix.lseek t.fd off Unix.SEEK_SET);
  let rec go n = if n < len then match Unix.read t.fd b n (len - n) with 0 -> n | k -> go (n + k) else n in
  go 0

let read_header t =
  let b = Bytes.make 100 '\000' in
  if read_at t 0 b 100 = 100 then Some b else None

let allocate t =
  t.n_pages <- t.n_pages + 1;
  t.n_pages

let read_page t npage =
  if npage > t.n_pages || npage <= 0 then raise (Bad_page npage);
  let data = Bytes.make t.page_size '\000' in
  ignore (read_at t ((npage - 1) * t.page_size) data t.page_size);
  { npage; data }

let write_page t (p : page) =
  if p.npage > t.n_pages then raise (Bad_page p.npage);
  ignore (Unix.lseek t.fd ((p.npage - 1) * t.page_size) Unix.SEEK_SET);
  let rec go n = if n < t.page_size then go (n + Unix.write t.fd p.data n (t.page_size - n)) in
  go 0

let close t = Unix.close t.fd
