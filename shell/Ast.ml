(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* The syntax tree of rc, as the parser builds it and the evaluator
 * walks it, and its printer: what whatis shows and what a function is
 * exported as (principia's pcmd.c, whose spacing it keeps: whatis's
 * output must read back as the same tree). *)

type word =
  | Word of string * bool           (* its text, and whether it was quoted *)
  | Dollar of word                  (* $x *)
  | Count of word                   (* $#x *)
  | Join of word                    (* dollar-quote x: the list joined *)
  | Sub of word * word list         (* $x(1 2) *)
  | Paren of word list              (* (a b c) *)
  | Concat of word * word           (* a^b, or a free caret *)
  | Backquote of word option * cmd  (* `{cmd}, `sep{cmd} *)
  | Pipefd of side * cmd            (* <{cmd}, >{cmd} *)

and redir =
  | Open of rkind * int * word      (* >f >>f <f <>f, on an fd *)
  | Here of int * heredoc           (* <<tag *)
  | Dup of int * int                (* >[a=b]: fd a becomes a copy of fd b *)
  | Close of int                    (* >[a=] *)

and rkind = Write | Append | Read | RdWr

(* a here document's body is read after its line, so the parser fills
 * it in later *)
and heredoc = { tag : string; expand : bool; mutable body : string }

(* <{cmd}: we read what cmd writes; >{cmd}: we write what it reads *)
and side = Reads | Writes

and cmd =
  | Empty
  | Simple of word list
  | Redirect of redir * cmd         (* applied, then the command *)
  | Seq of cmd * cmd
  | Async of cmd                    (* cmd & *)
  | And of cmd * cmd
  | Or of cmd * cmd
  | Not of cmd
  | Pipe of int * int * cmd * cmd   (* |[a=b]: the left's fd a to the right's b *)
  | Brace of cmd
  | Subshell of cmd                 (* @ cmd *)
  | If of cmd * cmd
  | IfNot of cmd
  | While of cmd * cmd
  | For of word * word list option * cmd   (* None: for(x), over $* *)
  | Switch of word * cmd
  | Match of word * word list       (* ~ subject patterns *)
  | Fn of word list * cmd option    (* None: delete *)
  | Assign of word * word * cmd option     (* x=v, or x=v cmd *)

(*****************************************************************************)
(* Printing (pcmd.c) *)
(*****************************************************************************)

(* a word needs quotes if it has a character rc would read otherwise
 * (fmt.c's needsrcquote), or is empty *)
let quote (s : string) : string =
  let special c = c <= ' ' || String.contains "`^#*[]=|\\?${}()'<>&;~!@\"" c in
  if s <> "" && not (String.exists special s) then s
  else "'" ^ String.concat "''" (String.split_on_char '\'' s) ^ "'"

let rec word (b : Buffer.t) (w : word) : unit =
  let p = Buffer.add_string b in
  match w with
  | Word (s, quoted) -> p (if quoted then quote s else s)
  | Dollar w -> p "$"; word b w
  | Count w -> p "$#"; word b w
  | Join w -> p "$\""; word b w
  | Sub (w, ws) -> p "$"; word b w; p "("; words b ws; p ")"
  | Paren ws -> p "("; words b ws; p ")"
  | Concat (a, c) -> word b a; p "^"; word b c
  | Backquote (sep, c) -> p "`"; Option.iter (word b) sep; p "{"; cmd b c; p "}"
  | Pipefd (side, c) -> p (match side with Reads -> "<{" | Writes -> ">{"); cmd b c; p "}"

(* a redirection's arrow, and the fd it means without [n] *)
and arrow (k : rkind) = match k with Write -> ">", 1 | Append -> ">>", 1 | Read -> "<", 0 | RdWr -> "<>", 0

and words b ws = List.iteri (fun i w -> if i > 0 then Buffer.add_char b ' '; word b w) ws

and redir b (r : redir) =
  let p = Buffer.add_string b in
  match r with
  | Open (k, fd, w) ->
      let arr, default = arrow k in
      p arr;
      if fd <> default then p (Printf.sprintf "[%d]" fd);
      word b w
  | Here (fd, h) ->
      p "<<";
      if fd <> 0 then p (Printf.sprintf "[%d]" fd);
      p (if h.expand then h.tag else quote h.tag)
  | Dup (a, c) -> p (Printf.sprintf ">[%d=%d]" a c)
  | Close a -> p (Printf.sprintf ">[%d=]" a)

and cmd (b : Buffer.t) (c : cmd) : unit =
  let p = Buffer.add_string b in
  match c with
  | Empty -> ()
  | Simple ws -> words b ws
  | Redirect ((Dup _ | Close _) as r, c) -> redir b r; cmd b c
  | Redirect (r, Empty) -> redir b r
  | Redirect (r, c) -> redir b r; p " "; cmd b c
  | Seq (Empty, c) | Seq (c, Empty) -> cmd b c
  | Seq (c1, c2) -> cmd b c1; p ";"; cmd b c2
  | Async c -> cmd b c; p "&"
  | And (c1, c2) -> cmd b c1; p " && "; cmd b c2
  | Or (c1, c2) -> cmd b c1; p " || "; cmd b c2
  | Not c -> p "! "; cmd b c
  | Pipe (l, r, c1, c2) ->
      cmd b c1; p "|";
      if r = 0 then (if l <> 1 then p (Printf.sprintf "[%d]" l))
      else p (Printf.sprintf "[%d=%d]" l r);
      cmd b c2
  | Brace c -> p "{"; cmd b c; p "}"
  | Subshell c -> p "@ "; cmd b c
  | If (cond, c) -> p "if("; cmd b cond; p ")"; cmd b c
  | IfNot c -> p "if not "; cmd b c
  | While (cond, c) -> p "while("; cmd b cond; p ")"; cmd b c
  | For (w, ws, c) ->
      p "for("; word b w;
      Option.iter (fun ws -> p " in "; words b ws) ws;
      p ")"; cmd b c
  | Switch (w, c) -> p "switch "; word b w; p " "; cmd b c
  | Match (w, ws) -> p "~ "; word b w; p " "; words b ws
  | Fn (ws, Some c) -> p "fn "; words b ws; p " "; cmd b c
  | Fn (ws, None) -> p "fn "; words b ws
  | Assign (x, v, None) -> word b x; p "="; word b v
  | Assign (x, v, Some c) -> word b x; p "="; word b v; p " "; cmd b c

let to_string (f : Buffer.t -> 'a -> unit) (x : 'a) : string =
  let b = Buffer.create 80 in
  f b x;
  Buffer.contents b
