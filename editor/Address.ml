(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Address.mli *)

type t = { input : Input.t; text : Text.t; mutable pattern : Regex.t option }

type range = { addr1 : int; addr2 : int; given : bool; last : int option; lastsep : int; cmd : int }

let error () = raise (Input.Error "")
let ch = Char.code

let read_pattern t delim =
  let input = t.input in
  let c = Input.getc input in
  let c = if c = Input.nl then (Input.unget input c; delim) else c in
  if c = delim then (if t.pattern = None then error ())
  else begin
    t.pattern <- None;
    let b = Buffer.create 32 in
    let add c = Buffer.add_utf_8_uchar b (Uchar.of_int c) in
    let rec go c =
      if c = ch '\\' then begin
        add c;
        let c = Input.getc input in
        if c = Input.nl || c = Input.eof then error ();
        add c
      end
      else add c;
      let c = Input.getc input in
      if c = Input.nl then Input.unget input c
      else if c <> delim && c <> Input.eof then go c
    in
    go c;
    t.pattern <- Some (try Regex.compile (Buffer.contents b) with Regex.Error _ -> error ())
  end

let matches t n =
  match t.pattern with
  | Some re when n > 0 -> Regex.exec re (Text.text t.text n) 0 <> None
  | _ -> false

(* ed.c's address(), its do-while and its continues kept *)
let address t : int option =
  let input = t.input and dol = Text.dol t.text in
  let a = ref (Text.dot t.text) and sign = ref 1 and opcnt = ref 0 and nextopand = ref (-1) in
  let result = ref None in
  let in_range () = 0 <= !a && !a <= dol in
  (try
     while (
       let rec blank () = let c = Input.getc input in if c = ch ' ' || c = ch '\t' then blank () else c in
       let c = blank () in
       let operand () = sign := 1; incr opcnt in
       if c >= ch '0' && c <= ch '9' then begin
         Input.unget input c;
         if !opcnt = 0 then a := 0;
         a := !a + (!sign * Input.digits input);
         operand ()
       end
       else if c = ch '$' || c = ch '.' then begin
         if c = ch '$' then a := dol;
         if !opcnt > 0 then error ();
         operand ()
       end
       else if c = ch '/' || c = ch '?' then begin
         if c = ch '?' then sign := - !sign;
         read_pattern t c;
         let b = !a in
         let rec search () =
           a := !a + !sign;
           if !a <= 0 then a := dol;
           if !a > dol then a := 0;
           if not (matches t !a) then (if !a = b then error () else search ())
         in
         search ();
         operand ()
       end
       else if c = ch '\'' then begin
         let c = Input.getc input in
         if !opcnt > 0 || c < ch 'a' || c > ch 'z' then error ();
         (match Text.find_mark t.text (Char.chr c) with Some n -> a := n | None -> a := dol + 1);
         operand ()
       end
       else begin
         (* a + or - with no number after it is 1 *)
         let skip = ref false in
         if !nextopand = !opcnt then begin
           a := !a + !sign;
           if not (in_range ()) then skip := true
         end;
         if not !skip then begin
           if c <> ch '+' && c <> ch '-' && c <> ch '^' then begin
             Input.unget input c;
             result := Some (if !opcnt = 0 then None else Some !a);
             raise Exit
           end;
           sign := if c = ch '+' then 1 else -1;
           incr opcnt;
           nextopand := !opcnt
         end
       end;
       in_range ())
     do () done
   with Exit -> ());
  match !result with Some r -> r | None -> error ()

let range t : range =
  let text = t.text and input = t.input in
  let addr1 = ref None in
  let rec loop c =
    let lastsep = c in
    let a1 = address t in
    let c = Input.getc input in
    if c <> ch ',' && c <> ch ';' then (lastsep, a1, c)
    else begin
      if lastsep = ch ',' then error ();
      let a1 = match a1 with Some a -> a | None -> if 1 > Text.dol text then 0 else 1 in
      addr1 := Some a1;
      if c = ch ';' then Text.set_dot text a1;
      loop c
    end
  in
  let lastsep, a1, cmd = loop Input.nl in
  let a1 = if lastsep <> Input.nl && a1 = None then Some (Text.dol text) else a1 in
  let addr2, given = match a1 with Some a -> a, true | None -> Text.dot text, false in
  { addr1 = Option.value !addr1 ~default:addr2; addr2; given; last = a1; lastsep; cmd }
