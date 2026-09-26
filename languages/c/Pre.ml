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
let includes : Fpath.t list ref = ref []
let peekc : char option ref = ref None

(* the end of the input: a NUL is no C *)
let eof = '\000'

(* lex.c's GETC: the next byte, popping what is exhausted *)
let rec raw () =
  match !stack with
  | [] -> eof
  | i :: rest ->
      if i.pos < String.length i.text then (let c = i.text.[i.pos] in i.pos <- i.pos + 1; c)
      else (stack := rest; raw ())

let push text = stack := { text; pos = 0 } :: !stack

(* the character put back, or the next *)
let read () = match !peekc with Some c -> peekc := None; c | None -> raw ()

let getc () =
  let c = read () in
  if c = '\n' then incr lineno;
  if c = eof then error_at !lineno "End of file";
  c

let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
let is_digit c = c >= '0' && c <= '9'
let is_alnum c = is_alpha c || is_digit c
let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\011' || c = '\012' || c = '\r'

(* the next non-space, stopping at a newline *)
let getnsc () =
  let rec go c = if not (is_space c) then c else if c = '\n' then (incr lineno; c) else go (raw ()) in
  go (read ())

let unget c = peekc := Some c; if c = '\n' then decr lineno

let index_of x l = let rec go i = function [] -> None | y :: r -> if y = x then Some i else go (i + 1) r in go 0 l

(*****************************************************************************)
(* The preprocessor (macbody) *)
(*****************************************************************************)

let getsym () =
  let c = getnsc () in
  if (not (is_alpha c)) && c <> '_' && c < '\128' then (unget c; None)
  else begin
    let b = Buffer.create 16 in
    let rec go c = if is_alnum c || c = '_' || c >= '\128' then (Buffer.add_char b c; go (getc ())) else unget c in
    go c;
    Some (lookup (Buffer.contents b))
  end

(* the rest of the line, its comments skipped: the character after *)
let getcom () =
  let rec go () =
    let c = getnsc () in
    if c <> '/' then c
    else
      let c = getc () in
      if c = '/' then (let rec eol c = if c <> '\n' then eol (getc ()) in eol c; '\n')
      else if c <> '*' then c
      else begin
        let rec skip c =
          if c = '*' then (let c = getc () in if c = '/' then getc () else skip c)
          else if c = '\n' then '\n'
          else skip (getc ())
        in
        let c = skip (getc ()) in
        if c = '\n' then '\n' else (unget c; go ())
      end
  in
  go ()

let macend () = let rec go () = let c = getnsc () in if c <> eof && c <> '\n' then go () in go ()

(* a macro is its number of parameters + 1 (0: none), varmac if the
 * last is ..., as a first character; then its body, a parameter as #a,
 * #b... *)
let varmac = 0x80

(* -Dname=value *)
let dodefine s =
  match String.index_opt s '=' with
  | Some i -> (lookup (String.sub s 0 i)).macro <- Some ("\000" ^ String.sub s (i + 1) (String.length s - i - 1))
  | None -> (lookup s).macro <- Some "\0001"

let macdef () =
  match getsym () with
  | None -> error_at !lineno "syntax in #define"
  | Some s ->
      let c = getc () in
      let args = ref [] and dots = ref false and n = ref (-1) in
      let c =
        if c = '(' then begin
          n := 0;
          let c = getnsc () in
          if c <> ')' then begin
            unget c;
            let rec params () =
              let a = match getsym () with
                | Some a -> a.name
                | None ->
                    let c = getnsc () in
                    if c = '.' && getc () = '.' && getc () = '.' then (dots := true; "__VA_ARGS__")
                    else error_at !lineno "syntax in #define: %s" s.name in
              args := !args @ [ a ];
              incr n;
              let c = getnsc () in
              if c = ')' then () else if c = ',' && not !dots then params () else error_at !lineno "syntax in #define: %s" s.name
            in
            params ()
          end;
          getc ()
        end
        else c
      in
      let c = if is_space c && c <> '\n' then getnsc () else c in
      let base = Buffer.create 64 in
      let add = Buffer.add_char base in
      (* q: the quote of the string or the character constant c is in *)
      let rec body c q =
        if q = None && (is_alpha c || c = '_') then begin
          let w = Buffer.create 16 in
          let rec word c = if is_alnum c || c = '_' then (Buffer.add_char w c; word (getc ())) else c in
          let c = word c in
          let w = Buffer.contents w in
          (match index_of w !args with Some i -> add '#'; add (Char.chr (97 + i)) | None -> Buffer.add_string base w);
          body c q
        end
        else if q <> None && c = '\\' then (add c; add (getc ()); body (next ()) q)
        else if q = Some c then (add c; body (next ()) None)
        else if q = None && (c = '"' || c = '\'') then (add c; body (getc ()) (Some c))
        else if q = None && c = '/' then begin
          let c = getc () in
          if c = '/' then (let rec eol c = if c <> '\n' then eol (getc ()) else c in body (eol (getc ())) q)
          else if c = '*' then begin
            let rec skip c =
              if c = '*' then (let c = getc () in if c <> '/' then skip c else getc ())
              else if c = '\n' then error_at !lineno "comment and newline in define: %s" s.name
              else skip (getc ())
            in
            body (skip (getc ())) q
          end
          else (add '/'; body c q)
        end
        else if c = '\\' then begin
          (* a line continued *)
          let c = getc () in
          if c = '\n' then body (getc ()) q
          else if c = '\r' then (let c = getc () in if c = '\n' then body (getc ()) q else (add '\\'; body c q))
          else (add '\\'; body c q)
        end
        else if c = '\n' then ()
        else begin
          if c = '#' && !n > 0 then add '#';
          add c;
          body (next ()) q
        end
      and next () =
        let c = raw () in
        if c = '\n' then incr lineno;
        if c = eof then error_at !lineno "eof in a macro: %s" s.name;
        c
      in
      body c None;
      let head = (!n + 1) lor (if !dots then varmac else 0) in
      s.macro <- Some (String.make 1 (Char.chr head) ^ Buffer.contents base)

(* the expansion of s, its arguments read from the input *)
let macexpand s =
  let m = Option.get s.macro in
  let head = Char.code m.[0] in
  let text = String.sub m 1 (String.length m - 1) in
  if head = 0 then text
  else begin
    let nargs = (head land lnot varmac) - 1 and dots = head land varmac <> 0 in
    if getnsc () <> '(' then error_at !lineno "syntax in macro expansion: %s" s.name;
    let args = ref [] and cur = Buffer.create 64 in
    let add = Buffer.add_char cur in
    let c = getc () in
    if c <> ')' then begin
      unget c;
      let rec arg level =
        let c = getc () in
        let quoted q =
          add c;
          let rec go () =
            let c = getc () in
            if c = '\\' then (add c; add (getc ()); go ())
            else if c = '\n' then error_at !lineno "syntax in macro expansion: %s" s.name
            else if c = q then add c
            else (add c; go ())
          in
          go ();
          arg level
        in
        if c = '"' || c = '\'' then quoted c
        else begin
          (* a comment is a space *)
          let c =
            if c <> '/' then Some c
            else
              let c2 = getc () in
              if c2 = '*' then (let rec skip () = let c = getc () in if c = '*' && getc () = '/' then () else skip () in skip (); None)
              else if c2 = '/' then (let rec eol () = if getc () <> '\n' then eol () in eol (); Some '\n')
              else (unget c2; Some '/')
          in
          match c with
          | None -> add ' '; arg level
          | Some c when level = 0 && c = ',' && not (List.length !args + 1 = nargs && dots) ->
              args := !args @ [ Buffer.contents cur ];
              Buffer.clear cur;
              if List.length !args > nargs then () else arg level
          | Some c when level = 0 && c = ')' -> args := !args @ [ Buffer.contents cur ]
          | Some c ->
              add (if c = '\n' then ' ' else c);
              arg (if c = '(' then level + 1 else if c = ')' then level - 1 else level)
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

let read_file = ref (fun (_ : Fpath.t) -> (None : string option))

let macinc () =
  let c0 = getnsc () in
  let close = if c0 = '"' then '"' else if c0 = '<' then '>' else error_at !lineno "syntax in #include" in
  let b = Buffer.create 32 in
  let rec go () = let c = getc () in if c = close then () else if c = '\n' then error_at !lineno "syntax in #include" else (Buffer.add_char b c; go ()) in
  go ();
  if getcom () <> '\n' then error_at !lineno "syntax in #include";
  let f = Buffer.contents b in
  let dirs = List.filteri (fun i _ -> not (i = 0 && close = '>')) !includes in
  let text = List.find_map (fun d -> !read_file (Fpath.append d (Fpath.v f))) dirs in
  match text with
  | Some t -> push t
  | None -> (match !read_file (Fpath.v f) with Some t -> push t | None -> error_at !lineno "cannot open include file %s" f)

type cond = Ifdef | Ifndef | Else

(* #ifdef, #ifndef, #else: skip what is not taken *)
let macif f =
  let skip () =
    let rec go bol l =
      let c = getc () in
      if c <> '#' then go (if c = '\n' then true else if not (is_space c) then false else bol) l
      else if not bol then go bol l
      else
        match getsym () with
        | None -> go bol l
        | Some { name = "endif"; _ } -> if l > 0 then go bol (l - 1) else macend ()
        | Some { name = "ifdef" | "ifndef"; _ } -> go bol (l + 1)
        | Some { name = "else"; _ } when l = 0 && f <> Else -> macend ()
        | Some _ -> go bol l
    in
    go true 0
  in
  if f = Else then skip ()
  else
    match getsym () with
    | None -> error_at !lineno "syntax in #if(n)def"
    | Some s ->
        if getcom () <> '\n' then error_at !lineno "syntax in #if(n)def";
        if (s.macro <> None) <> (f = Ifndef) then () else skip ()

(* #pragma profile: off makes TEXT's flag NOPROF *)
let profile = ref true

let domacro () =
  let s = match getsym () with Some s -> s | None -> lookup "endif" in
  match s.name with
  | "ifdef" -> macif Ifdef
  | "ifndef" -> macif Ifndef
  | "else" -> macif Else
  | "define" -> macdef ()
  | "include" -> macinc ()
  | "undef" -> (match getsym () with Some s -> macend (); s.macro <- None | None -> error_at !lineno "syntax in #undef")
  | "pragma" -> (
      (* profile's the one that reaches the code: TEXT's flag *)
      match getsym () with
      | Some { name = "profile"; _ } ->
          let on = match getsym () with
            | Some { name = "on" | "yes"; _ } -> true
            | Some { name; _ } -> (match int_of_string_opt (String.sub name 1 (String.length name - 1)) with Some n -> n <> 0 | None -> false)
            | None -> false in
          profile := on;
          macend ()
      | _ -> macend ())
  | "line" | "endif" -> macend ()
  | n -> error_at !lineno "unknown #: %s" n
