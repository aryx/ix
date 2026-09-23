(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Command.mli *)

type caps = < Cap.fork; Cap.exec; Cap.wait; Cap.open_in; Cap.open_out >

(* a replacement, as compsub reads it: a \ before a character *)
type rhs = Char of int | Escaped of int

type t = {
  caps : caps;
  ad : Address.t;
  verbose : bool;
  mutable savedfile : string;          (* the remembered file name *)
  mutable file : string;               (* the one of this command *)
  mutable addr1 : int;
  mutable addr2 : int;
  mutable given : bool;
  mutable pflag : bool;                (* print dot after this command *)
  mutable count : int;                 (* runes read or written *)
  mutable bpagesize : int;
  mutable bformat : bool;
  mutable bnum : bool;
}

exception Quit

let ch = Char.code
let error () = raise (Input.Error "")
let input t = t.ad.input
let text t = t.ad.text
let getc t = Input.getc (input t)
let unget t c = Input.unget (input t) c

let create caps input ~verbose ~filter =
  Out.to_stderr := filter;
  { caps = (caps :> caps); ad = { input; text = Text.create (); pattern = None }; verbose;
    savedfile = (if filter then "/dev/stdout" else ""); file = "";
    addr1 = 0; addr2 = 0; given = false; pflag = false; count = 0;
    bpagesize = 20; bformat = false; bnum = false }

(*****************************************************************************)
(* Helpers *)
(*****************************************************************************)

(* ed.c's setwide, squeeze, nonzero, setnoaddr *)
let setwide t = if not t.given then (t.addr1 <- (if Text.dol (text t) > 0 then 1 else 0); t.addr2 <- Text.dol (text t))
let squeeze t i = if t.addr1 < i || t.addr2 > Text.dol (text t) || t.addr1 > t.addr2 then error ()
let nonzero t = squeeze t 1
let setnoaddr t = if t.given then error ()

(* the end of a command: a newline, or p, l or n then a newline *)
let newline t =
  let c = getc t in
  if c <> Input.nl && c <> Input.eof then begin
    if c = ch 'p' || c = ch 'l' || c = ch 'n' then begin
      t.pflag <- true;
      if c = ch 'l' then Out.listf := true else if c = ch 'n' then Out.listn := true;
      if getc t <> Input.nl then error ()
    end
    else error ()
  end

let add_rune b c = Buffer.add_utf_8_uchar b (Uchar.of_int c)

(* ed.c's filename: a blank then a name up to the newline, or none for
 * the remembered one *)
let filename t comm =
  t.count <- 0;
  let c = getc t in
  if c = Input.nl || c = Input.eof then begin
    if t.savedfile = "" && comm <> 'f' then error ();
    t.file <- t.savedfile
  end
  else begin
    if c <> ch ' ' then error ();
    let rec blanks () = let c = getc t in if c = ch ' ' then blanks () else c in
    let c = blanks () in
    if c = Input.nl then error ();
    let b = Buffer.create 32 in
    let rec go c =
      if c = ch ' ' || c = Input.eof then error ();
      add_rune b c;
      let c = getc t in
      if c <> Input.nl then go c
    in
    go c;
    t.file <- Buffer.contents b;
    if t.savedfile = "" || comm = 'e' || comm = 'f' then t.savedfile <- t.file
  end

let print_range t =
  nonzero t;
  for n = t.addr1 to t.addr2 do
    if !Out.listn then (Out.putd n; Out.putchr (ch '\t'));
    Out.putst (Text.text (text t) n)
  done;
  Text.set_dot (text t) t.addr2;
  Out.listf := false;
  Out.listn := false;
  t.pflag <- false

let quit t =
  if t.verbose && Text.changed (text t) && Text.dol (text t) > 0 then begin
    Text.set_changed (text t) false;
    error ()
  end;
  raise Quit

let runes s = let n = ref 0 in String.iter (fun c -> if Char.code c land 0xc0 <> 0x80 then incr n) s; !n

let exfile t = if t.verbose then (Out.putd t.count; Out.putchr (ch '\n'))

(*****************************************************************************)
(* Files *)
(*****************************************************************************)

(* the lines of a file, as ed.c's getfile reads them: counted in runes,
 * a missing last newline added (and said), a line cut at a NUL *)
let read_file t (fd : Unix.file_descr) : string list =
  let ic = Unix.in_channel_of_descr fd in
  let s = In_channel.input_all ic in
  close_in ic;
  if s = "" then []
  else begin
    let s = if s.[String.length s - 1] <> '\n' then (Out.putst "'\\n' appended"; s ^ "\n") else s in
    t.count <- t.count + runes s;
    let lines = String.split_on_char '\n' s in
    List.filteri (fun i _ -> i < List.length lines - 1) lines
    |> List.map (fun l -> match String.index_opt l '\000' with Some i -> String.sub l 0 i | None -> l)
  end

let read t =
  let fd =
    try Unix.openfile t.file [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0
    with Unix.Unix_error _ -> Input.set_lastc (input t) Input.nl; raise (Input.Error t.file)
  in
  setwide t;
  squeeze t 0;
  let was_empty = Text.dol (text t) = 0 in
  ignore (Text.append (text t) t.addr2 (read_file t fd));
  exfile t;
  Text.set_changed (text t) (not was_empty)

let write t append =
  let flags = Unix.[ O_WRONLY; O_CREAT; O_CLOEXEC ] @ if append then [ Unix.O_APPEND ] else [ Unix.O_TRUNC ] in
  let fd = try Unix.openfile t.file flags 0o666 with Unix.Unix_error _ -> raise (Input.Error t.file) in
  let b = Buffer.create 4096 in
  if Text.dol (text t) > 0 then
    for n = t.addr1 to t.addr2 do
      let l = Text.text (text t) n in
      Buffer.add_string b l;
      Buffer.add_char b '\n';
      t.count <- t.count + runes l + 1
    done;
  let oc = Unix.out_channel_of_descr fd in
  (try Buffer.output_buffer oc b; close_out oc with Sys_error _ -> error ());
  exfile t

(*****************************************************************************)
(* Substitution *)
(*****************************************************************************)

(* ed.c's compsub: the pattern, the replacement, and g *)
let compsub t =
  let seof = getc t in
  if seof = Input.nl || seof = ch ' ' then error ();
  Address.read_pattern t.ad seof;
  let rec rhs acc =
    let c = getc t in
    if c = ch '\\' then rhs (Escaped (getc t) :: acc)
    else if (c = Input.nl && not (Input.global_has_more (input t))) || c = Input.eof then begin
      unget t c;
      t.pflag <- true;
      List.rev acc
    end
    else if c = seof then List.rev acc
    else rhs (Char c :: acc)
  in
  let r = rhs [] in
  let c = getc t in
  let global = c = ch 'g' in
  if not global then unget t c;
  newline t;
  r, global

(* ed.c's dosub: [line] with its match replaced; and where the search
 * goes on, the end of the replacement *)
let dosub (rhs : rhs list) (line : string) (subs : (int * int) array) : string * int =
  let s, e = subs.(0) in
  let b = Buffer.create (String.length line + 16) in
  Buffer.add_string b (String.sub line 0 s);
  List.iter (function
    | Char c when c = ch '&' -> Buffer.add_string b (String.sub line s (e - s))
    | Escaped c when c >= ch '1' && c <= ch '8' ->
        let gs, ge = subs.(c - ch '0') in
        if gs < 0 then error ();
        Buffer.add_string b (String.sub line gs (ge - gs))
    | Char c | Escaped c -> add_rune b c) rhs;
  let loc2 = Buffer.length b in
  Buffer.add_string b (String.sub line e (String.length line - e));
  Buffer.contents b, loc2

let substitute t =
  let inglob = Input.in_global (input t) in
  let n = Input.digits (input t) in
  let rhs, gsubf = compsub t in
  let re = match t.ad.pattern with Some re -> re | None -> error () in
  let changed = ref false in
  let a1 = ref t.addr1 in
  while !a1 <= t.addr2 do
    let tx = text t in
    (match Regex.exec re (Text.text tx !a1) 0 with
     | None -> ()
     | Some subs ->
         let line = ref (Text.text tx !a1) and subs = ref subs and m = ref n in
         let rec loop () =
           let s, e = !subs.(0) in
           let from = ref e and stop = ref false in
           decr m;
           if !m <= 0 then begin
             let l, loc2 = dosub rhs !line !subs in
             line := l;
             from := loc2;
             if not gsubf then stop := true
             else if s = e then begin
               if loc2 >= String.length l then stop := true
               else from := loc2 + Uchar.utf_decode_length (String.get_utf_8_uchar l loc2)
             end
           end;
           if not !stop then
             match Regex.exec re !line !from with Some s -> subs := s; loop () | None -> ()
         in
         loop ();
         if !m <= 0 then begin
           changed := true;
           (* a newline in the result makes several lines *)
           match String.split_on_char '\n' !line with
           | [] -> ()
           | first :: rest ->
               let old = Text.get tx !a1 in
               let line = { Text.text = first; global = false } in
               Text.renamed tx old line;
               Text.set_undo tx (Some (old, line));
               Text.replace tx !a1 line;
               Text.set_changed tx true;
               let nl = Text.append tx !a1 rest in
               Text.set_dot tx (!a1 + nl);
               t.addr2 <- t.addr2 + nl;
               a1 := !a1 + nl
         end);
    incr a1
  done;
  if not !changed && not inglob then error ()

(*****************************************************************************)
(* The commands *)
(*****************************************************************************)

(* input mode: lines until "." *)
let text_lines t =
  let rec lines acc = match Input.line (input t) with Some "." | None -> List.rev acc | Some l -> lines (l :: acc) in
  lines []

let add t i =
  if i && (t.given || Text.dol (text t) > 0) then (t.addr1 <- t.addr1 - 1; t.addr2 <- t.addr2 - 1);
  squeeze t 0;
  newline t;
  let ls = text_lines t in
  Text.set_dot (text t) t.addr2;
  ignore (Text.append (text t) t.addr2 ls)

(* ed.c's move: m, and t (a copy at the end first, then moved) *)
let move t copy =
  nonzero t;
  let adt = match Address.address t.ad with Some a -> a | None -> error () in
  newline t;
  let tx = text t in
  let ad1, ad2 =
    if copy then begin
      let dol = Text.dol tx in
      let lines = List.init (t.addr2 - t.addr1 + 1) (fun i -> Text.text tx (t.addr1 + i)) in
      ignore (Text.append tx dol lines);
      dol + 1, Text.dol tx
    end
    else begin
      for n = t.addr1 to t.addr2 do (Text.get tx n).global <- false done;
      t.addr1, t.addr2
    end
  in
  if adt < ad1 then begin
    if adt + 1 = ad1 then Text.set_dot tx (adt + (ad2 - ad1 + 1)) else Text.move tx ad1 ad2 adt
  end
  else if adt > ad2 then Text.move tx ad1 ad2 adt
  else error ()

let join t =
  nonzero t;
  let tx = text t in
  let joined = String.concat "" (List.init (t.addr2 - t.addr1 + 1) (fun i -> Text.text tx (t.addr1 + i))) in
  Text.replace tx t.addr1 { Text.text = joined; global = false };
  Text.set_changed tx true;
  if t.addr1 < t.addr2 then Text.delete tx (t.addr1 + 1) t.addr2;
  Text.set_dot tx t.addr1

let browse t =
  let forward = ref true in
  let c = getc t in
  unget t c;
  if c <> Input.nl then begin
    if c = ch '-' || c = ch '+' then (if c = ch '-' then forward := false; ignore (getc t));
    let n = Input.digits (input t) in
    if n > 0 then t.bpagesize <- n
  end;
  newline t;
  if t.pflag then (t.bformat <- !Out.listf; t.bnum <- !Out.listn)
  else (Out.listf := t.bformat; Out.listn := t.bnum);
  let dol = Text.dol (text t) in
  if !forward then (t.addr1 <- t.addr2; t.addr2 <- min dol (t.addr2 + t.bpagesize))
  else (t.addr1 <- max 1 (t.addr2 - t.bpagesize));
  print_range t

let callunix t =
  setnoaddr t;
  let b = Buffer.create 80 in
  let rec go () = let c = getc t in if c <> Input.eof && c <> Input.nl then (add_rune b c; go ()) in
  go ();
  Out.flush ();
  let pid = CapUnix.fork t.caps () in
  if pid = 0 then begin
    let path = String.split_on_char ':' (try Sys.getenv "PATH" with Not_found -> "/bin") in
    List.iter (fun d ->
      try CapUnix.execv t.caps (Filename.concat d "rc") [| "rc"; "-c"; Buffer.contents b |] with _ -> ()) path;
    Unix._exit 1
  end;
  let rec wait () = try ignore (CapUnix.waitpid t.caps [] pid) with Unix.Unix_error (Unix.EINTR, _, _) -> wait () in
  wait ();
  if t.verbose then Out.putst "!"

(* the loop, until the end of its input *)
let rec commands t =
  if t.pflag then begin
    t.pflag <- false;
    t.addr1 <- Text.dot (text t);
    t.addr2 <- t.addr1;
    print_range t
  end;
  let r = Address.range t.ad in
  t.addr1 <- r.addr1;
  t.addr2 <- r.addr2;
  t.given <- r.given;
  let tx = text t in
  let c = r.cmd in
  if c = Input.eof then ()
  else begin
    (match Char.chr (if c < 0 || c > 255 then 0 else c) with
     | 'r' -> filename t 'r'; read t
     | ('w' | 'W') as w ->
         setwide t;
         squeeze t (if Text.dol tx > 0 then 1 else 0);
         let q = getc t in
         let q = if q = ch 'q' || q = ch 'Q' then q else (unget t q; 0) in
         filename t w;
         write t (w = 'W');
         if t.addr1 <= 1 && t.addr2 = Text.dol tx then Text.set_changed tx false;
         if q = ch 'Q' then Text.set_changed tx false;
         if q <> 0 then quit t
     | 'l' -> Out.listf := true; newline t; print_range t
     | 'p' | 'P' -> newline t; print_range t
     | '\n' ->
         let a1 = match r.last with Some a -> a | None -> Text.dot tx + 1 in
         if r.last = None then (t.addr1 <- a1; t.addr2 <- a1);
         if r.lastsep = ch ';' then t.addr1 <- a1;
         print_range t
     | 'f' -> setnoaddr t; filename t 'f'; Out.putst t.savedfile
     | '=' -> setwide t; squeeze t 0; newline t; Out.putd t.addr2; Out.putchr (ch '\n')
     | 'a' -> add t false
     | 'i' -> add t true
     | 'Q' -> Text.set_changed tx false; setnoaddr t; newline t; quit t
     | 'q' -> setnoaddr t; newline t; quit t
     | 'd' -> nonzero t; newline t; Text.delete tx t.addr1 t.addr2
     | 'c' ->
         nonzero t;
         newline t;
         Text.delete tx t.addr1 t.addr2;
         let ls = text_lines t in
         Text.set_dot tx (t.addr1 - 1);
         ignore (Text.append tx (t.addr1 - 1) ls)
     | 'm' -> move t false
     | 't' -> move t true
     | 's' -> nonzero t; substitute t
     | 'u' -> (
         nonzero t;
         newline t;
         match Text.undo tx with
         | Some (old, line) when Text.get tx t.addr2 == line ->
             Text.replace tx t.addr2 old;
             Text.set_dot tx t.addr2
         | _ -> error ())
     | 'k' ->
         nonzero t;
         let c = getc t in
         if c < ch 'a' || c > ch 'z' then error ();
         newline t;
         Text.mark tx (Char.chr c) t.addr2
     | 'g' -> global t true
     | 'v' -> global t false
     | '!' -> callunix t
     | 'n' -> Out.listn := true; newline t; print_range t
     | 'j' -> if not t.given then t.addr2 <- t.addr2 + 1; newline t; join t
     | 'b' -> nonzero t; browse t
     | ('e' | 'E') as e ->
         if e = 'E' then Text.set_changed tx false;
         setnoaddr t;
         if t.verbose && Text.changed tx then (Text.set_changed tx false; error ());
         filename t 'e';
         Text.clear tx;
         t.addr2 <- 0;
         read t
     | _ -> error ());
    commands t
  end

(* ed.c's global: mark the lines, then run the list on each *)
and global t k =
  let input = input t and tx = text t in
  if Input.in_global input then error ();
  setwide t;
  squeeze t (if Text.dol tx > 0 then 1 else 0);
  let c = Input.getc input in
  if c = Input.nl then error ();
  Address.read_pattern t.ad c;
  let b = Buffer.create 80 in
  let rec list () =
    let c = Input.getc input in
    if c <> Input.nl then begin
      if c = Input.eof then error ();
      if c = ch '\\' then begin
        let c = Input.getc input in
        if c <> Input.nl then Buffer.add_char b '\\';
        add_rune b c
      end
      else add_rune b c;
      list ()
    end
  in
  list ();
  if Buffer.length b = 0 then Buffer.add_char b 'p';
  Buffer.add_char b '\n';
  let cmds = Buffer.contents b in
  for n = 0 to Text.dol tx do
    let l = Text.get tx n in
    l.global <- n >= t.addr1 && n <= t.addr2 && Address.matches t.ad n = k
  done;
  if cmds = "d\n" then Text.delete_global tx
  else begin
    let rec next n =
      let tx = text t in
      if n <= Text.dol tx then begin
        let l = Text.get tx n in
        if l.global then begin
          l.global <- false;
          Text.set_dot tx n;
          Input.set_global input (Some cmds);
          commands t;
          next 0
        end
        else next (n + 1)
      end
    in
    next 0
  end

let rescue t =
  let tx = text t in
  if Text.dol tx > 0 then begin
    t.addr1 <- 1;
    t.addr2 <- Text.dol tx;
    t.file <- "ed.hup";
    (try write { t with verbose = false } false with _ -> ())
  end

(* the error: ?, or ?file, after the clean-up *)
let report t msg =
  Out.listf := false;
  Out.listn := false;
  t.pflag <- false;
  t.count <- 0;
  Input.recover (input t);
  Out.putchr (ch '?');
  Out.putst msg

let run t ~file =
  (match file with
   | Some f -> t.savedfile <- f; Input.set_global (input t) (Some "r")
   | None -> if !Out.to_stderr then Input.set_global (input t) (Some "a"));
  let rec top () =
    match commands t; quit t with
    | () -> ()
    | exception Input.Error msg -> report t msg; top ()
    (* an interrupt: a newline, ?, and back to the loop (ed.c's notifyf) *)
    | exception Sys.Break -> Out.putchr (ch '\n'); Input.set_lastc (input t) Input.nl; report t ""; top ()
    | exception Quit -> ()
  in
  top ();
  Out.flush ()
