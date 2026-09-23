(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Pre.mli *)

open Tree

(*****************************************************************************)
(* The input: files and macro expansions, stacked (lex.c's Io) *)
(*****************************************************************************)

type input = { text : string; mutable pos : int }

let stack : input list ref = ref []
let includes : string list ref = ref []
let peekc : int option ref = ref None
let eof = -1

(* lex.c's GETC: the next byte, popping what is exhausted *)
let rec raw () =
  match !stack with
  | [] -> eof
  | i :: rest ->
      if i.pos < String.length i.text then (let c = Char.code i.text.[i.pos] in i.pos <- i.pos + 1; c)
      else (stack := rest; raw ())

let push text = stack := { text; pos = 0 } :: !stack

let getc () =
  let c = match !peekc with Some c -> peekc := None; c | None -> raw () in
  if c = Char.code '\n' then incr lineno;
  if c = eof then error_at !lineno "End of file";
  c

(* the next non-space, stopping at a newline *)
let getnsc () =
  let rec go c =
    if c >= 0x80 || not (c = 32 || c = 9 || c = 11 || c = 12 || c = 13 || c = 10) then c
    else if c = 10 then (incr lineno; c)
    else go (raw ())
  in
  go (match !peekc with Some c -> peekc := None; c | None -> raw ())

let unget c = peekc := Some c; if c = 10 then decr lineno

let index_of x l = let rec go i = function [] -> None | y :: r -> if y = x then Some i else go (i + 1) r in go 0 l

let is_alpha c = (c >= 97 && c <= 122) || (c >= 65 && c <= 90)
let is_digit c = c >= 48 && c <= 57
let is_alnum c = is_alpha c || is_digit c
let is_space c = c = 32 || c = 9 || c = 10 || c = 11 || c = 12 || c = 13
let chr = Char.chr

(*****************************************************************************)
(* The preprocessor (macbody) *)
(*****************************************************************************)

let getsym () =
  let c = getnsc () in
  if (not (is_alpha c)) && c <> 95 && c < 0x80 then (unget c; None)
  else begin
    let b = Buffer.create 16 in
    let rec go c = if is_alnum c || c = 95 || c >= 0x80 then (Buffer.add_char b (chr c); go (getc ())) else unget c in
    go c;
    Some (lookup (Buffer.contents b))
  end

(* the rest of the line, its comments skipped: the character after *)
let getcom () =
  let rec go () =
    let c = getnsc () in
    if c <> 47 then c
    else
      let c = getc () in
      if c = 47 then (let rec eol c = if c <> 10 then eol (getc ()) in eol c; 10)
      else if c <> 42 then c
      else begin
        let rec skip c =
          if c = 42 then (let c = getc () in if c = 47 then getc () else skip c)
          else if c = 10 then 10
          else skip (getc ())
        in
        let c = skip (getc ()) in
        if c = 10 then 10 else (unget c; go ())
      end
  in
  go ()

let macend () = let rec go () = let c = getnsc () in if c >= 0 && c <> 10 then go () in go ()

(* -Dname=value *)
let dodefine s =
  match String.index_opt s '=' with
  | Some i -> (lookup (String.sub s 0 i)).macro <- Some ("\000" ^ String.sub s (i + 1) (String.length s - i - 1))
  | None -> (lookup s).macro <- Some "\0001"

let varmac = 0x80

let macdef () =
  match getsym () with
  | None -> error_at !lineno "syntax in #define"
  | Some s ->
      let c = getc () in
      let args = ref [] and dots = ref false and n = ref (-1) in
      let c =
        if c = 40 then begin
          n := 0;
          let c = getnsc () in
          if c <> 41 then begin
            unget c;
            let rec params () =
              let a = match getsym () with
                | Some a -> a.name
                | None ->
                    let c = getnsc () in
                    if c = 46 && getc () = 46 && getc () = 46 then (dots := true; "__VA_ARGS__")
                    else error_at !lineno "syntax in #define: %s" s.name in
              args := !args @ [ a ];
              incr n;
              let c = getnsc () in
              if c = 41 then () else if c = 44 && not !dots then params () else error_at !lineno "syntax in #define: %s" s.name
            in
            params ()
          end;
          getc ()
        end
        else c
      in
      let c = if is_space c && c <> 10 then getnsc () else c in
      let base = Buffer.create 64 in
      let rec body c ischr =
        if ischr = 0 && (is_alpha c || c = 95) then begin
          let w = Buffer.create 16 in
          let rec word c = if is_alnum c || c = 95 then (Buffer.add_char w (chr c); word (getc ())) else c in
          let c = word c in
          let w = Buffer.contents w in
          (match index_of w !args with
           | Some i -> Buffer.add_char base '#'; Buffer.add_char base (chr (97 + i))
           | None -> Buffer.add_string base w);
          body c ischr
        end
        else if ischr <> 0 && c = 92 then (Buffer.add_char base (chr c); let c = getc () in Buffer.add_char base (chr c); body (next ()) ischr)
        else if ischr <> 0 && c = ischr then (Buffer.add_char base (chr c); body (next ()) 0)
        else if ischr = 0 && (c = 34 || c = 39) then (Buffer.add_char base (chr c); body (getc ()) c)
        else if ischr = 0 && c = 47 then begin
          let c = getc () in
          if c = 47 then (let rec eol c = if c <> 10 then eol (getc ()) else c in body (eol (getc ())) ischr)
          else if c = 42 then begin
            let rec skip c =
              if c = 42 then (let c = getc () in if c <> 47 then skip c else getc ())
              else if c = 10 then error_at !lineno "comment and newline in define: %s" s.name
              else skip (getc ())
            in
            body (skip (getc ())) ischr
          end
          else (Buffer.add_char base '/'; body c ischr)
        end
        else if c = 92 then begin
          let c = getc () in
          if c = 10 then body (getc ()) ischr
          else if c = 13 then (let c = getc () in if c = 10 then body (getc ()) ischr else (Buffer.add_char base '\\'; body c ischr))
          else (Buffer.add_char base '\\'; body c ischr)
        end
        else if c = 10 then ()
        else begin
          if c = 35 && !n > 0 then Buffer.add_char base '#';
          Buffer.add_char base (chr c);
          body (next ()) ischr
        end
      and next () =
        let c = raw () in
        if c = 10 then incr lineno;
        if c = eof then error_at !lineno "eof in a macro: %s" s.name;
        c
      in
      body c 0;
      let head = (!n + 1) lor (if !dots then varmac else 0) in
      s.macro <- Some (String.make 1 (chr head) ^ Buffer.contents base)

(* the expansion of s, its arguments read from the input *)
let macexpand s =
  let m = Option.get s.macro in
  let head = Char.code m.[0] in
  let text = String.sub m 1 (String.length m - 1) in
  if head = 0 then text
  else begin
    let nargs = (head land lnot varmac) - 1 and dots = head land varmac <> 0 in
    if getnsc () <> 40 then error_at !lineno "syntax in macro expansion: %s" s.name;
    let args = ref [] and cur = Buffer.create 64 in
    let c = getc () in
    if c <> 41 then begin
      unget c;
      let rec arg level =
        let c = getc () in
        let quoted q =
          Buffer.add_char cur (chr c);
          let rec go () =
            let c = getc () in
            if c = 92 then (Buffer.add_char cur (chr c); Buffer.add_char cur (chr (getc ())); go ())
            else if c = 10 then error_at !lineno "syntax in macro expansion: %s" s.name
            else if c = q then Buffer.add_char cur (chr c)
            else (Buffer.add_char cur (chr c); go ())
          in
          go ();
          arg level
        in
        if c = 34 then quoted 34
        else if c = 39 then quoted 39
        else begin
          let c =
            if c = 47 then begin
              let c2 = getc () in
              if c2 = 42 then (let rec skip () = let c = getc () in if c = 42 && getc () = 47 then () else skip () in skip (); -2)
              else if c2 = 47 then (let rec eol () = if getc () <> 10 then eol () in eol (); 10)
              else (unget c2; 47)
            end
            else c
          in
          if c = -2 then (Buffer.add_char cur ' '; arg level)
          else if level = 0 && c = 44 && not (List.length !args + 1 = nargs && dots) then begin
            args := !args @ [ Buffer.contents cur ];
            Buffer.clear cur;
            if List.length !args > nargs then () else arg level
          end
          else if level = 0 && c = 41 then args := !args @ [ Buffer.contents cur ]
          else begin
            Buffer.add_char cur (chr (if c = 10 then 32 else c));
            arg (if c = 40 then level + 1 else if c = 41 then level - 1 else level)
          end
        end
      in
      arg 0
    end;
    if List.length !args <> nargs then error_at !lineno "argument mismatch expanding: %s" s.name;
    let b = Buffer.create 128 in
    let n = String.length text in
    let rec go i =
      if i < n then
        let c = text.[i] in
        if c <> '#' then (Buffer.add_char b (if c = '\n' then ' ' else c); go (i + 1))
        else if i + 1 < n && text.[i + 1] = '#' then (Buffer.add_char b '#'; go (i + 2))
        else if i + 1 < n then begin
          let a = Char.code text.[i + 1] - 97 in
          if a >= 0 && a < List.length !args then Buffer.add_string b (List.nth !args a);
          go (i + 2)
        end
    in
    go 0;
    Buffer.contents b
  end

let read_file = ref (fun (_ : string) -> (None : string option))

let macinc () =
  let c0 = getnsc () in
  let close = if c0 = 34 then 34 else if c0 = 60 then 62 else error_at !lineno "syntax in #include" in
  let b = Buffer.create 32 in
  let rec go () = let c = getc () in if c = close then () else if c = 10 then error_at !lineno "syntax in #include" else (Buffer.add_char b (chr c); go ()) in
  go ();
  if getcom () <> 10 then error_at !lineno "syntax in #include";
  let f = Buffer.contents b in
  let dirs = List.filteri (fun i _ -> not (i = 0 && close = 62)) !includes in
  let text = List.find_map (fun d -> !read_file (if d = "." then f else Filename.concat d f)) dirs in
  match text with
  | Some t -> push t
  | None -> (match !read_file f with Some t -> push t | None -> error_at !lineno "cannot open include file %s" f)

(* #ifdef, #ifndef, #else: skip what is not taken *)
let macif f =
  let skip () =
    let rec go bol l =
      let c = getc () in
      if c <> 35 then go (if c = 10 then true else if not (is_space c) then false else bol) l
      else if not bol then go bol l
      else
        match getsym () with
        | None -> go bol l
        | Some { name = "endif"; _ } -> if l > 0 then go bol (l - 1) else macend ()
        | Some { name = "ifdef" | "ifndef"; _ } -> go bol (l + 1)
        | Some { name = "else"; _ } when l = 0 && f <> 2 -> macend ()
        | Some _ -> go bol l
    in
    go true 0
  in
  if f = 2 then skip ()
  else
    match getsym () with
    | None -> error_at !lineno "syntax in #if(n)def"
    | Some s ->
        if getcom () <> 10 then error_at !lineno "syntax in #if(n)def";
        if (s.macro <> None) <> (f = 1) then () else skip ()

let domacro () =
  let s = match getsym () with Some s -> s | None -> lookup "endif" in
  match s.name with
  | "ifdef" -> macif 0
  | "ifndef" -> macif 1
  | "else" -> macif 2
  | "define" -> macdef ()
  | "include" -> macinc ()
  | "undef" -> (match getsym () with Some s -> macend (); s.macro <- None | None -> error_at !lineno "syntax in #undef")
  | "line" | "pragma" | "endif" -> macend ()
  | n -> error_at !lineno "unknown #: %s" n
