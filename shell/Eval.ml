(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Eval.mli *)
open Ast

type caps = < Process.caps; Cap.chdir; Cap.env >

type t = {
  env : Env.t;
  caps : caps;
  argv0 : string;
  mutable ifnot : bool;        (* the last if's condition was false *)
  mutable apids : int list;    (* started with & *)
}

exception Exit of string
exception Error of string

let create (caps : < caps; .. >) ~argv0 env =
  { env; caps = (caps :> caps); argv0; ifnot = false; apids = [] }

let env t = t.env
let caps t = t.caps
let argv0 t = t.argv0
let background t = t.apids
let forget t pid = t.apids <- List.filter (( <> ) pid) t.apids

let builtins : (string, t -> string list -> unit) Hashtbl.t = Hashtbl.create 17

let print s = print_string s; flush stdout
let eprint s = prerr_string s; flush stderr

(* SIGINT only sets this; the next command acts on it (trap.c's notes,
 * delivered between instructions: here, between commands) *)
let interrupted = ref false

let set_status t s = Env.set_status t.env s
let ok t = Env.ok t.env

(* in a child: run [f], and exit with its status *)
let child t (f : unit -> unit) : int =
  try f (); Process.code (Env.status t.env) with
  | Exit s -> Process.code s
  | Error m | Word.Error m -> if m <> "" then eprint (Printf.sprintf "rc (%s): %s\n" t.argv0 m); 1

(*****************************************************************************)
(* Words *)
(*****************************************************************************)

let readdir d =
  match Sys.readdir (if d = "" then "." else d) with
  | names -> Some (Array.to_list names)
  | exception Sys_error _ -> None

let exists f = Sys.file_exists f

let rec ctx t : Word.ctx = {
  var = Env.get t.env;
  backquote = (fun _seps c ->
    let r, w = Process.pipe () in
    let pid = Process.fork t.caps (fun () ->
      Process.close r; Process.dup2 w 1; Process.close w; child t (fun () -> run t c)) in
    Process.close w;
    let out = Process.read_all r in
    Process.close r;
    (* the command's status is the backquote's *)
    set_status t (Process.wait t.caps pid);
    out);
  pipefd = (fun read c ->
    (* the command's end is a child's fd 1 (or 0); ours stays open, and
     * its name is the word *)
    let r, w = Process.pipe () in
    let mine, theirs, fd = if read then r, w, 1 else w, r, 0 in
    let _pid = Process.fork t.caps (fun () ->
      Process.close mine; Process.dup2 theirs fd; Process.close theirs; child t (fun () -> run t c)) in
    Process.close theirs;
    Printf.sprintf "/dev/fd/%d" mine);
}

and expand t w = try Word.expand (ctx t) w with Word.Error m -> raise (Error m)

and words t (ws : word list) : string list =
  List.concat_map (fun w -> List.concat_map (Glob.files ~readdir ~exists) (expand t w)) ws

and singleton t w = try Word.singleton (ctx t) w with Word.Error m -> raise (Error m)

(*****************************************************************************)
(* Commands *)
(*****************************************************************************)

(* -e: a failed command ends rc *)
and check t ~e = if e && Env.flag t.env 'e' && not (ok t) then raise (Exit (Env.status t.env))

(* fn sigint, if there is one; else a script ends, and the terminal
 * gets its prompt back *)
and interrupt t =
  interrupted := false;
  match Env.fn t.env "sigint" with
  | Some body -> run t body
  | None -> if Env.flag t.env 'i' then raise (Error "") else raise (Exit "interrupt")

and run_e t ~e (c : cmd) : unit =
  if !interrupted then interrupt t;
  match c with
  | Empty -> ()
  | Simple ws -> simple t (words t ws); check t ~e
  | Redirect (r, Simple [ Word ("exec", false) ]) -> redirect t r ~keep:true (fun () -> ())
  | Redirect (r, c) -> redirect t r ~keep:false (fun () -> run_e t ~e c)
  | Seq (a, b) -> run_e t ~e a; run_e t ~e b
  | Async c ->
      let pid = Process.fork t.caps (fun () ->
        let null = Process.open_file t.caps Read "/dev/null" in
        Process.dup2 null 0; Process.close null;
        child t (fun () -> run_e t ~e c)) in
      Env.set t.env "apid" [ string_of_int pid ];
      t.apids <- pid :: t.apids
  | And (a, b) -> run_e t ~e:false a; if ok t then run_e t ~e b
  | Or (a, b) -> run_e t ~e:false a; if not (ok t) then run_e t ~e b
  | Not c -> run_e t ~e:false c; set_status t (if ok t then "false" else "")
  | Pipe (l, r, a, b) ->
      let rd, wr = Process.pipe () in
      let pid = Process.fork t.caps (fun () ->
        Process.close rd; Process.dup2 wr l; Process.close wr; child t (fun () -> run_e t ~e a)) in
      Process.close wr;
      let right =
        Process.with_fds [ r ] (fun () ->
          Process.dup2 rd r; Process.close rd; run_e t ~e b; Env.status t.env)
      in
      let left = Process.wait t.caps pid in
      set_status t (left ^ "|" ^ right)
  | Brace c -> run_e t ~e c
  | Subshell c ->
      let pid = Process.fork t.caps (fun () -> child t (fun () -> run_e t ~e c)) in
      set_status t (Process.wait t.caps pid);
      check t ~e
  | If (cond, body) ->
      run_e t ~e:false cond;
      t.ifnot <- true;
      if ok t then (run_e t ~e body; t.ifnot <- false)
  | IfNot body -> if t.ifnot then run_e t ~e body
  | While (cond, body) ->
      let rec loop () =
        if cond = Empty then set_status t "" else run_e t ~e:false cond;
        if ok t then (run_e t ~e body; loop ())
      in
      loop ()
  | For (x, list, body) ->
      let name = singleton t x in
      let values = match list with None -> Env.get t.env "*" | Some ws -> words t ws in
      Env.local t.env name (Env.get t.env name) (fun () ->
        values |> List.iter (fun v -> Env.set t.env name [ v ]; run_e t ~e body))
  | Switch (w, body) ->
      let subject = String.concat " " (List.map Glob.to_string (expand t w)) in
      let rec flat = function Seq (a, b) -> flat a @ flat b | Brace c -> flat c | Empty -> [] | c -> [ c ] in
      let rec go matched = function
        | [] -> ()
        | Simple (Word ("case", false) :: pats) :: rest ->
            if not matched then
              go (List.exists (fun p -> Glob.matches p subject) (List.concat_map (expand t) pats)) rest
        | c :: rest -> if matched then run_e t ~e c; go matched rest
      in
      go false (flat body)
  | Match (w, pats) ->
      let subject = String.concat " " (List.map Glob.to_string (expand t w)) in
      let pats = List.concat_map (expand t) pats in
      set_status t (if List.exists (fun p -> Glob.matches p subject) pats then "" else "no match");
      check t ~e
  | Fn (names, body) -> List.iter (fun n -> Env.set_fn t.env n body) (words t names)
  | Assign (x, v, None) -> Env.set t.env (singleton t x) (words t [ v ])
  | Assign (x, v, Some c) -> Env.local t.env (singleton t x) (words t [ v ]) (fun () -> run_e t ~e c)

and run t c = run_e t ~e:true c

(* a function, a builtin, or a program (simple.c's Xsimple) *)
and simple t (args : string list) : unit =
  match args with
  | [] -> raise (Error "empty argument list")
  | name :: rest ->
      if Env.flag t.env 'x' then eprint (String.concat " " (List.map Ast.quote args) ^ "\n");
      match Env.fn t.env name with
      | Some body -> Env.local t.env "*" rest (fun () -> run t body)
      | None -> command t name rest

and command t name rest =
  match name, rest with
  | "builtin", [] -> eprint "builtin: empty argument list\n"; set_status t "empty arg list"
  | "builtin", n :: r -> command t n r
  | _ -> (
      match Hashtbl.find_opt builtins name with
      | Some f -> f t rest
      | None ->
          let path = Env.get t.env "path" and env = Env.export t.env in
          let pid = Process.fork t.caps (fun () -> Process.exec t.caps ~path ~env (name :: rest)) in
          set_status t (Process.wait t.caps pid))

(* a redirection around [f]; with [~keep], for exec, not undone *)
and redirect t (r : redir) ~keep (f : unit -> unit) : unit =
  let target = function
    | Open (_, fd, _) | Here (fd, _) -> fd
    | Dup (a, _) | Close a -> a
  in
  let apply () =
    match r with
    | Open (k, fd, w) ->
        let file =
          match words t [ w ] with
          | [ file ] -> file
          | l ->
              let op = match k with Write -> ">" | Append -> ">>" | Read -> "<" | RdWr -> "<>" in
              (* claude: 9base's messages for < and > (not >>) end with a
               * newline of their own *)
              raise (Error (op ^ (if l = [] then " requires file" else " requires singleton")
                            ^ if k = Append then "" else "\n"))
        in
        let n =
          try Process.open_file t.caps k file
          with Unix.Unix_error (e, _, _) ->
            (* claude: 9base's words for it: file: rc (argv0): can't open: why *)
            eprint (Printf.sprintf "%s: rc (%s): can't open: %s\n" file t.argv0 (Unix.error_message e));
            raise (Error "")
        in
        Process.dup2 n fd;
        Process.close n
    | Here (fd, h) ->
        (* the body through a pipe, from a child *)
        let body = if h.expand then heredoc t h.body else h.body in
        let rd, wr = Process.pipe () in
        let pid = Process.fork t.caps (fun () -> Process.close rd; Process.write wr body; 0) in
        ignore pid;
        Process.close wr;
        Process.dup2 rd fd;
        Process.close rd
    | Dup (a, b) -> Process.dup2 b a
    | Close a -> Process.close a
  in
  if keep then (flush stdout; flush stderr; apply (); f ())
  else Process.with_fds [ target r ] (fun () -> apply (); f ())

(* here.c's psubst: in a here document $name is its value, joined by
 * spaces, $1 an argument, $$ a $; a ^ right after the name is eaten,
 * and a $ before anything else is dropped (an empty name) *)
and heredoc t (s : string) : string =
  let b = Buffer.create (String.length s) and n = String.length s in
  let idchr c = c > ' ' && not (String.contains "!\"#$%&'()+,-./:;<=>?@[\\]^`{|}~" c) in
  let rec go i =
    if i < n then
      if s.[i] <> '$' then (Buffer.add_char b s.[i]; go (i + 1))
      else if i + 1 < n && s.[i + 1] = '$' then (Buffer.add_char b '$'; go (i + 2))
      else begin
        let j = ref (i + 1) in
        while !j < n && idchr s.[!j] do incr j done;
        let name = String.sub s (i + 1) (!j - i - 1) in
        let v =
          match int_of_string_opt name with
          | Some k when k > 0 -> (match List.nth_opt (Env.get t.env "*") (k - 1) with Some v -> [ v ] | None -> [])
          | _ -> Env.get t.env name
        in
        Buffer.add_string b (String.concat " " v);
        go (if !j < n && s.[!j] = '^' then !j + 1 else !j)
      end
  in
  go 0;
  Buffer.contents b

(*****************************************************************************)
(* Reading commands *)
(*****************************************************************************)

let source t ~name ~interactive (lx : Lexer.t) : unit =
  let rec loop () =
    match Parser.line lx with
    | None -> ()
    | Some c ->
        (try run t c with
         | (Error m | Word.Error m) when interactive ->
             if m <> "" then eprint (Printf.sprintf "rc (%s): %s\n" t.argv0 m);
             set_status t m);
        loop ()
    | exception (Parser.Error m | Lexer.Error m) ->
        let where =
          match name with
          | Some f when not interactive -> Printf.sprintf "%s:%d: " f (Lexer.line lx)
          | Some f -> f ^ ": "
          | None -> Printf.sprintf "line %d: " (Lexer.line lx)
        in
        eprint ("rc: " ^ where ^ m ^ "\n");
        set_status t "syntax error";
        if interactive then loop ()
  in
  loop ()
