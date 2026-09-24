(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Mkfile.mli *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type attrs = {
  virtual_ : bool;
  quiet : bool;
  delete : bool;
  noerror : bool;
  norecipe : bool;
  novirtual : bool;
  regexp : bool;
  prog : string option;
}

type rule = {
  target : string;
  pattern : Pattern.t;
  alltargets : string list;
  prereqs : string list;
  recipe : string;
  attrs : attrs;
  id : int;
  shell : string list;
  file : string;
  line : int;
}

type t = {
  vars : (string, string list) Hashtbl.t;
  here : (string, unit) Hashtbl.t;         (* set by a mkfile or argument *)
  noexport : (string, unit) Hashtbl.t;     (* X=U=... *)
  overridden : (string, unit) Hashtbl.t;   (* set on the command line *)
  chains : (string, rule list) Hashtbl.t;  (* target -> its rules *)
  mutable metas : rule list;               (* reversed *)
  mutable default : string list;
  mutable nlines : int;
  mutable default_shell : string list;
}

exception Error of string

type io = {
  read_file : string -> string option;
  output : t -> shell:string list -> stdin:bool -> string -> string * bool;
  warn : string -> unit;
}

let no_attrs = {
  virtual_ = false; quiet = false; delete = false; noerror = false;
  norecipe = false; novirtual = false; regexp = false; prog = None;
}

let create ~(env : (string * string) list) ~(default_shell : string list) : t =
  let t = {
    vars = Hashtbl.create 101; here = Hashtbl.create 101;
    noexport = Hashtbl.create 7; overridden = Hashtbl.create 7;
    chains = Hashtbl.create 101; metas = []; default = []; nlines = 0;
    default_shell;
  } in
  env |> List.iter (fun (k, v) -> Hashtbl.replace t.vars k [v]);
  t

(*****************************************************************************)
(* Variables and rules *)
(*****************************************************************************)

let lookup t name = Hashtbl.find_opt t.vars name
let set t name vs = Hashtbl.replace t.vars name vs
let set_here t name = Hashtbl.mem t.here name

let exported t =
  Hashtbl.fold (fun k v acc ->
    if Hashtbl.mem t.noexport k then acc else (k, v) :: acc) t.vars []
  |> List.sort compare

let chain t target = Option.value (Hashtbl.find_opt t.chains target) ~default:[]

(* a metarule's target text names no file: mk '%.o' finds no rule *)
let rules_for t name = List.filter (fun (r : rule) -> not (Pattern.is_meta r.pattern)) (chain t name)
let metarules t = List.rev t.metas
let default_targets t = t.default
let default_shell t = t.default_shell
let set_default_shell t shell = t.default_shell <- shell

(* rule.c's addrule: one target of a rule line *)
let add_one t (r : rule) : unit =
  let chain = chain t r.target in
  match List.find_opt (fun (old : rule) -> old.prereqs = r.prereqs) chain with
  | Some old ->
      Hashtbl.replace t.chains r.target (List.map (fun x -> if x == old then r else x) chain);
      t.metas <- List.map (fun x -> if x == old then r else x) t.metas
  | None ->
      Hashtbl.replace t.chains r.target
        (match chain with [] -> [ r ] | first :: rest -> first :: r :: rest);
      if Pattern.is_meta r.pattern then t.metas <- r :: t.metas

let add_rules t ~file ~line ~shell ~targets ~prereqs ~recipe (attrs : attrs) =
  t.nlines <- t.nlines + 1;
  let has_pct s = String.contains s '%' || String.contains s '&' in
  if t.default = [] && not attrs.regexp && not (List.exists has_pct targets) then
    t.default <- targets;
  targets |> List.iter (fun target ->
    let pattern =
      try Pattern.of_target ~regexp:attrs.regexp target
      with _ -> raise (Error (Printf.sprintf "%s:%d: bad regular expression %s" file line target))
    in
    add_one t { target; pattern; alltargets = targets; prereqs; recipe; attrs;
                id = t.nlines; shell; file; line })

let add_rule t ~targets ~prereqs ~recipe attrs =
  add_rules t ~file:"<command line>" ~line:0 ~shell:t.default_shell ~targets ~prereqs
    ~recipe attrs

(*****************************************************************************)
(* The input *)
(*****************************************************************************)

type input = {
  file : string;
  text : string;
  mutable pos : int;
  mutable line : int;
  mutable shell : string list;   (* this file's own MKSHELL *)
}

let error (inp : input) line fmt =
  Printf.ksprintf (fun s ->
    raise (Error (Printf.sprintf "%s:%d: syntax error; %s" inp.file line s))) fmt

let peek inp = if inp.pos < String.length inp.text then Some inp.text.[inp.pos] else None

let getc inp =
  match peek inp with
  | None -> None
  | Some c -> inp.pos <- inp.pos + 1; if c = '\n' then inp.line <- inp.line + 1; Some c

(* lex.c's nextrune: an escaped newline is deleted, or, inside a quote
 * or a backquote, becomes a blank *)
let rec nextc inp ~elide =
  let n = String.length inp.text in
  if inp.pos + 1 < n && inp.text.[inp.pos] = '\\' && inp.text.[inp.pos + 1] = '\n'
  then begin
    inp.pos <- inp.pos + 2;
    inp.line <- inp.line + 1;
    if elide then nextc inp ~elide else Some ' '
  end
  else getc inp

(* copy a quoted token as is, its quotes included (lex.c's escapetoken
 * with preserve): the quotes are removed later, by Word.split *)
let copy_quoted q inp buf (open_ : char) =
  let line = inp.line in
  let rec go () =
    match nextc inp ~elide:false with
    | None -> error inp line "missing closing %c" open_
    | Some c ->
        Buffer.add_char buf c;
        if c = '\\' && open_ = '"' then
          (match getc inp with Some c -> Buffer.add_char buf c; go () | None -> go ())
        else if c <> open_ then go ()
        else if q = Word.Rc && peek inp = Some '\'' then
          (Buffer.add_char buf '\''; ignore (getc inp); go ())
  in
  match q, open_ with
  | Word.Sh, '\\' -> (match getc inp with Some c -> Buffer.add_char buf c | None -> ())
  | _ -> go ()

(*****************************************************************************)
(* Lines *)
(*****************************************************************************)

(* lex.c's assline: the next non-empty line, comments removed,
 * backquotes run *)
let assline io t inp : string option =
  let buf = Buffer.create 80 in
  let nonempty () = if Buffer.length buf > 0 then Some (Buffer.contents buf) else None in
  let q () = Word.quoting_of_shell inp.shell in
  let rec loop () =
    match nextc inp ~elide:true with
    | None -> nonempty ()
    | Some '\n' -> if Buffer.length buf > 0 then nonempty () else loop ()
    | Some '#' ->
        let rec skip prev =
          match getc inp with None -> None | Some '\n' -> Some prev | Some c -> skip c
        in
        (match skip '#' with
         | None -> nonempty ()
         | Some '\\' -> loop ()   (* an escaped newline in a comment continues *)
         | Some _ -> if Buffer.length buf > 0 then nonempty () else loop ())
    | Some c when Word.opens_quote (q ()) c ->
        Buffer.add_char buf c; copy_quoted (q ()) inp buf c; loop ()
    | Some '`' -> backquote (); loop ()
    | Some c -> Buffer.add_char buf c; loop ()
  and backquote () =
    let line = inp.line in
    let rec skip_blanks () =
      match getc inp with Some (' ' | '\t') -> skip_blanks () | c -> c
    in
    let first, term =
      match skip_blanks () with
      | Some '{' -> skip_blanks (), '}'
      | c -> c, '`'
    in
    let cmd = Buffer.create 80 in
    let rec collect c =
      match c with
      | None | Some '\n' -> error inp line "missing closing %c after `" term
      | Some c when c = term ->
          let out, _ok = io.output t ~shell:inp.shell ~stdin:true (Buffer.contents cmd ^ "\n") in
          Buffer.add_string buf out
      | Some c when Word.opens_quote (q ()) c ->
          Buffer.add_char cmd c; copy_quoted (q ()) inp cmd c; collect (nextc inp ~elide:false)
      | Some c -> Buffer.add_char cmd c; collect (nextc inp ~elide:false)
    in
    collect first
  in
  loop ()

(* parse.c's rbody: the lines that start with a blank (the blank
 * dropped), or with a # (kept: the shell ignores it, but it makes a
 * recipe -- a comment right after a rule header is its recipe) *)
let rbody inp : string =
  let buf = Buffer.create 80 in
  let rec line_start () =
    match peek inp with
    | Some '#' -> rest ()
    | Some (' ' | '\t') -> ignore (getc inp); rest ()
    | _ -> ()
  and rest () =
    match getc inp with
    | None -> ()
    | Some '\n' -> Buffer.add_char buf '\n'; line_start ()
    | Some c -> Buffer.add_char buf c; rest ()
  in
  line_start ();
  Buffer.contents buf

(* the attributes between the two colons of a rule header, e.g. "VQ" or
 * "Pcmp -s"; [s] starts after the first colon; returns them and the
 * index after the second colon *)
let rule_attrs inp line (s : string) : attrs * int =
  let n = String.length s in
  let rec go i (a : attrs) =
    if i >= n then error inp line "missing trailing :"
    else match s.[i] with
      | ':' -> a, i + 1
      | 'V' -> go (i + 1) { a with virtual_ = true }
      | 'Q' -> go (i + 1) { a with quiet = true }
      | 'D' -> go (i + 1) { a with delete = true }
      | 'E' -> go (i + 1) { a with noerror = true }
      | 'N' -> go (i + 1) { a with norecipe = true }
      | 'n' -> go (i + 1) { a with novirtual = true }
      | 'R' -> go (i + 1) { a with regexp = true }
      | 'I' -> go (i + 1) a   (* omk's interactive attribute, accepted as principia's mk does *)
      | 'P' -> (
          match String.index_from_opt s (i + 1) ':' with
          | None -> error inp line "missing trailing :"
          | Some j -> go j { a with prog = Some (String.sub s (i + 1) (j - i - 1)) })
      | c -> error inp line "unknown attribute '%c'" c
  in
  if n = 0 || s.[0] = ' ' || s.[0] = '\t' then no_attrs, 0 else go 0 no_attrs

(*****************************************************************************)
(* Main algorithm *)
(*****************************************************************************)

let rec read_input ~override io t inp : unit =
  match assline io t inp with
  | None -> ()
  | Some text ->
      (* mk numbers a line after reading it: the line after the header *)
      let line = inp.line in
      let q = Word.quoting_of_shell inp.shell in
      let words s =
        try Word.split q ~lookup:(lookup t) s
        with Word.Error msg -> error inp line "%s" msg
      in
      let n = String.length text in
      (match Word.find_unquoted q text ~from:0 ":=<" with
       | None -> error inp line "expected one of :<="
       | Some i ->
           let head = String.sub text 0 i in
           let rest from = String.sub text from (n - from) in
           (match text.[i] with
            | '<' when i + 1 < n && text.[i + 1] = '|' ->
                let cmd = String.concat " " (words (rest (i + 2))) in
                if cmd = "" then error inp line "missing include program name";
                let out, ok = io.output t ~shell:inp.shell ~stdin:false cmd in
                include_text ~override io t ~file:cmd out;
                if not ok then error inp line "bad include program status"
            | '<' -> (
                let file = String.concat " " (words (rest (i + 1))) in
                if file = "" then error inp line "missing include file name";
                match io.read_file file with
                | None ->
                    io.warn (Printf.sprintf
                      "warning: skipping missing include file %s: No such file or directory" file)
                | Some text -> include_text ~override io t ~file text)
            | '=' ->
                let from = i + 1 in
                let unexport, from =
                  match Word.find_unquoted q text ~from "= \t" with
                  | Some j when text.[j] = '=' ->
                      let a = String.sub text from (j - from) in
                      String.iter (fun c ->
                        if c <> 'U' then error inp line "unknown attribute '%c'" c) a;
                      a <> "", j + 1
                  | _ -> false, from
                in
                (match words head with
                 | [ name ] ->
                     let value = words (rest from) in
                     let set_it =
                       if Hashtbl.mem t.overridden name then override
                       else (if override then Hashtbl.replace t.overridden name (); true)
                     in
                     if set_it then begin
                       Hashtbl.replace t.vars name value;
                       Hashtbl.replace t.here name ();
                       if name = "MKSHELL" then inp.shell <- value
                     end;
                     if unexport then Hashtbl.replace t.noexport name ()
                 | [] -> error inp line "no var on left side of assignment"
                 | _ -> error inp line "multiple vars on left side of assignment")
            | _ (* ':' *) ->
                let attrs, skip = rule_attrs inp line (rest (i + 1)) in
                let targets = words head in
                if targets = [] then error inp line "no target on left side of rule";
                let prereqs = words (rest (i + 1 + skip)) in
                let recipe = rbody inp in
                add_rules t ~file:inp.file ~line ~shell:inp.shell ~targets ~prereqs
                  ~recipe attrs));
      read_input ~override io t inp

(* an included file has its own MKSHELL, starting from the default *)
and include_text ~override io t ~file text =
  let saved = lookup t "MKSHELL" in
  read_input ~override io t { file; text; pos = 0; line = 1; shell = t.default_shell };
  match saved with
  | Some v -> Hashtbl.replace t.vars "MKSHELL" v
  | None -> Hashtbl.remove t.vars "MKSHELL"

let read ?(override = false) io t ~file text =
  read_input ~override io t { file; text; pos = 0; line = 1; shell = t.default_shell }

(*****************************************************************************)
(* Debug *)
(*****************************************************************************)

let dump t =
  let b = Buffer.create 1000 in
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) t.vars [] |> List.sort compare
  |> List.iter (fun (k, v) ->
    if Hashtbl.mem t.here k then
      Printf.bprintf b "%s = %s\n" k (String.concat " " v));
  let rule (r : rule) =
    Printf.bprintf b "%s:%d: %s: %s\n" r.file r.line r.target (String.concat " " r.prereqs)
  in
  Hashtbl.fold (fun _ rs acc -> rs @ acc) t.chains []
  |> List.sort (fun (a : rule) b -> compare (a.id, a.target) (b.id, b.target))
  |> List.iter rule;
  Buffer.contents b
