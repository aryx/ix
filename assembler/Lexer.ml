(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Lexer.mli *)

type token =
  | Ident of string
  | Int of int64
  | Float of float
  | String of string
  | Punct of string      (* ( ) [ ] , $ : + - * / % & | ^ ~ = < > << >> -> @> <> *)
  | Eol                  (* a newline or a ; *)

exception Error of int * string

(* the preprocessor, as much of it as the inputs use: #include "file",
 * and #define NAME text, substituted word by word in the lines after
 * it (goken's darwin libc: numbers_arm64.h). An included file's lines
 * take the place of the #include, so a line number counts from the top
 * of the result. *)
let preprocess caps (dir : Fpath.t) (text : string) : string =
  let defs = Hashtbl.create 16 in
  let subst line =
    if Hashtbl.length defs = 0 then line
    else begin
      let b = Buffer.create (String.length line) and n = String.length line in
      let rec go i =
        if i < n then
          if (line.[i] >= 'A' && line.[i] <= 'Z') || (line.[i] >= 'a' && line.[i] <= 'z') || line.[i] = '_' then begin
            let j = ref i in
            while !j < n && (let c = line.[!j] in (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_') do incr j done;
            let w = String.sub line i (!j - i) in
            Buffer.add_string b (Option.value (Hashtbl.find_opt defs w) ~default:w);
            go !j
          end
          else (Buffer.add_char b line.[i]; go (i + 1))
      in
      go 0;
      Buffer.contents b
    end
  in
  String.split_on_char '\n' text
  |> List.map (fun line ->
    let t = String.trim line in
    if String.length t > 8 && String.sub t 0 8 = "#include" then begin
      let f = String.trim (String.sub t 8 (String.length t - 8)) in
      let f = String.sub f 1 (String.length f - 2) in
      let path = Fpath.append dir (Fpath.v f) in
      let inc = Files.read caps path in
      (* its #defines, kept for the lines after *)
      String.split_on_char '\n' inc |> List.iter (fun l ->
        match String.split_on_char ' ' (String.trim (String.map (fun c -> if c = '\t' then ' ' else c) l)) |> List.filter (( <> ) "") with
        | "#define" :: name :: value -> Hashtbl.replace defs name (String.concat " " value)
        | _ -> ());
      ""
    end
    else if String.length t > 7 && String.sub t 0 7 = "#define" then begin
      (match String.split_on_char ' ' (String.map (fun c -> if c = '\t' then ' ' else c) t) |> List.filter (( <> ) "") with
       | _ :: name :: value -> Hashtbl.replace defs name (String.concat " " value)
       | _ -> ());
      ""
    end
    else subst line)
  |> String.concat "\n"

let is_ident_start c = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c = '_' || c = '.' || c = '\xc2'
let is_ident c = is_ident_start c || (c >= '0' && c <= '9') || c = '\xb7'
let is_digit c = c >= '0' && c <= '9'

(* the tokens of a file, each with its line *)
let tokens (text : string) : (token * int) list =
  let n = String.length text and line = ref 1 and acc = ref [] in
  let add t = acc := (t, !line) :: !acc in
  let rec go i =
    if i < n then
      let c = text.[i] in
      if c = '\n' then (add Eol; incr line; go (i + 1))
      else if c = ';' then (add Eol; go (i + 1))
      else if c = ' ' || c = '\t' || c = '\r' then go (i + 1)
      else if c = '/' && i + 1 < n && text.[i + 1] = '/' then
        go (match String.index_from_opt text i '\n' with Some j -> j | None -> n)
      else if c = '/' && i + 1 < n && text.[i + 1] = '*' then begin
        let rec close j =
          if j + 1 >= n then raise (Error (!line, "unterminated comment"))
          else if text.[j] = '*' && text.[j + 1] = '/' then j + 2
          else (if text.[j] = '\n' then incr line; close (j + 1))
        in
        go (close (i + 2))
      end
      else if c = '#' then raise (Error (!line, "no preprocessor: # lines are not supported"))
      else if is_digit c then begin
        let j = ref i in
        while !j < n && (is_ident text.[!j] || ((text.[!j] = '+' || text.[!j] = '-') && (text.[!j - 1] = 'e' || text.[!j - 1] = 'E') && not (String.contains (String.sub text i (!j - i)) 'x'))) do incr j done;
        let s = String.sub text i (!j - i) in
        let is_float = String.contains s '.' || ((String.contains s 'e' || String.contains s 'E') && not (String.contains s 'x' || String.contains s 'X')) in
        if is_float then add (Float (float_of_string s))
        else begin
          (* 0x.., 0.. octal, decimal; unsigned 64-bit values wrap *)
          let s' = if String.length s > 1 && s.[0] = '0' && s.[1] <> 'x' && s.[1] <> 'X' then "0o" ^ String.sub s 1 (String.length s - 1) else s in
          match Int64.of_string_opt s' with
          | Some v -> add (Int v)
          | None -> (match Int64.of_string_opt ("0u" ^ s) with Some v -> add (Int v) | None -> raise (Error (!line, "bad number " ^ s)))
        end;
        go !j
      end
      else if is_ident_start c then begin
        let j = ref (i + 1) in
        (* a $ inside a name: 5c's static locals, x$7<> *)
        while !j < n && (is_ident text.[!j] || (text.[!j] = '$' && !j + 1 < n && is_digit text.[!j + 1])) do incr j done;
        add (Ident (String.sub text i (!j - i)));
        go !j
      end
      else if c = '"' then begin
        let b = Buffer.create 16 in
        let rec str j =
          if j >= n then raise (Error (!line, "unterminated string"))
          else match text.[j] with
            | '"' -> j + 1
            | '\\' when j + 1 < n ->
                let e = text.[j + 1] in
                if e >= '0' && e <= '7' then begin
                  let k = ref (j + 1) and v = ref 0 in
                  while !k < n && !k < j + 4 && text.[!k] >= '0' && text.[!k] <= '7' do
                    v := (!v * 8) + Char.code text.[!k] - 48; incr k done;
                  Buffer.add_char b (Char.chr (!v land 255));
                  str !k
                end
                else begin
                  Buffer.add_char b (match e with 'n' -> '\n' | 't' -> '\t' | 'r' -> '\r' | 'b' -> '\b' | 'f' -> '\012' | 'z' -> '\000' | c -> c);
                  str (j + 2)
                end
            | c -> Buffer.add_char b c; str (j + 1)
        in
        let j = str (i + 1) in
        add (String (Buffer.contents b));
        go j
      end
      else if c = '\'' && i + 2 < n && text.[i + 2] = '\'' then (add (Int (Int64.of_int (Char.code text.[i + 1]))); go (i + 3))
      else begin
        let two = if i + 1 < n then String.sub text i 2 else "" in
        if List.mem two [ "<<"; ">>"; "->"; "@>"; "<>" ] then (add (Punct two); go (i + 2))
        else if String.contains "()[],$:+-*/%&|^~=<>@" c then (add (Punct (String.make 1 c)); go (i + 1))
        else raise (Error (!line, Printf.sprintf "unexpected character %C" c))
      end
  in
  go 0;
  add Eol;
  List.rev !acc
