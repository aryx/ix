(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny shell, in one file: pipes, redirections, variables and basic
 * control flow. TinyRc (shell/) is rc, faithfully; this is what is left
 * when compatibility is dropped, written after it, from what it taught.
 * The language is rc's, cut down:
 *
 *     ls -l *.c | wc -l >count         words, globs, a pipe, redirections
 *     x=(a b c); echo $x $#x $x.o      lists, the only value; a.o b.o c.o
 *     for(f in *.c) cc -c $f           if(cmd) cmd   while(cmd) cmd
 *     test -f x && echo y || echo n    ! cmd   { cmds }   @{ cmds }
 *     fn f { echo $1 }; f a            functions, $* $1 $2 ...
 *     y=`{date}; sleep 1 &; wait       command output as words; &
 *     cc -c x.c >[2]errs >[2=1]        other fds
 *     ~ $x *.c && echo matched         matching: ~ subject pattern ...
 *
 * What is kept from rc, and why it is the core:
 *
 * - {b Every value is a list of strings.} $x is never split again, so
 *   there is no quoting of $x, no "$@", and $* is the arguments as they
 *   were. The only quote is '...' ('' inside is a quote).
 * - {b Words next to each other are joined, distributing over lists}:
 *   $x.o is a.o b.o c.o, and two lists of the same length join
 *   pairwise. rc does this with a "free caret" that its lexer inserts;
 *   here a word simply is the pieces with nothing between them, and ^
 *   is only a way to write two pieces with nothing between.
 * - {b Only the literal text globs}: a * from a variable or a quote is
 *   a *. The trick: such characters are escaped (a \000 before them)
 *   as the word is built, so the matcher sees which is which; the
 *   escapes go once the files are found.
 * - {b Redirections are done in the shell, around the command, and
 *   undone after} (the fds are copied away, then put back), so a
 *   function or a brace sees them as a program does.
 * - {b The syntax tree is walked}: a child forked for a pipe's stage
 *   or a subshell walks its subtree, and exits; the last stage of a
 *   pipe runs in the shell itself.
 * - {b $status is a string}: "" for success, the exit code, or the
 *   signal; a pipe's is its stages' joined by |.
 *
 * What is dropped, each a few lines of TinyRc, and none needed by the
 * recipes of xix's mkfiles (this shell's test, below): switch and if
 * not, here documents, a list joined into one word and subscripts,
 * `sep{} and <{}, `{} inside a word, eval and ., the builtins but cd
 * exit shift wait and ~, functions in the environment, a $path apart
 * from $PATH, -x, rcmain, signals, and the interactive prompt.
 * Exercises, roughly in that order.
 *
 * The tests: test.sh runs scripts of this subset through it and
 * through 9base's rc, which must print the same; and TinyMk builds
 * all of xix with it as its shell (MKSHELL, through a link named rc,
 * so that TinyMk exports lists the way rc wants them, joined by \001).
 *
 * Usage: tinyshell [-e] [-c cmd | file] [arg ...]   (-e: a command that
 * fails, not in a condition, ends the shell; -I and -i are accepted)
 *
 * References: Tom Duff, "Rc -- The Plan 9 Shell" (1990), for the
 * language, and for the principle the lists are there to keep: input
 * "is never scanned more than once"; D. M. Ritchie and K. Thompson,
 * "The UNIX Time-Sharing System" (CACM, 1974), for fork and exec as
 * two calls, between which a child sets up its own file descriptors,
 * and the shell as an ordinary program. *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type piece =
  | Lit of string * bool     (* text, quoted *)
  | Var of string            (* $x, $1, $* *)
  | Count of string          (* $#x *)
  | Back of cmd              (* `{cmd} *)

and word = piece list        (* the pieces, joined *)

and cmd =
  | Empty
  | Simple of word list * redir list
  | Seq of cmd * cmd
  | Async of cmd
  | And of cmd * cmd
  | Or of cmd * cmd
  | Not of cmd
  | Pipe of cmd * cmd
  | Brace of cmd * redir list
  | Subshell of cmd
  | If of cmd * cmd
  | While of cmd * cmd
  | For of string * word list option * cmd
  | Fn of string * cmd
  | Assign of string * word list * cmd option   (* x=v, or x=v cmd *)

and redir = Open of int * mode * word | Dup of int * int

(* < > >> *)
(* old: the Unix.open_flag list itself, which said the kind only to open *)
and mode = Read | Write | Append

exception Error of string
exception Exit of string

type caps = < Cap.fork; Cap.exec; Cap.wait; Cap.chdir >

(*****************************************************************************)
(* Lexing *)
(*****************************************************************************)

type token =
  | WORD of word | BACKQ | SEMI | AMP | NL | EOF | PIPE | ANDAND | OROR
  | LPAREN | RPAREN | LBRACE | RBRACE | REDIR of redir

type lexer = { text : string; mutable pos : int }

let peekc lx = if lx.pos < String.length lx.text then Some lx.text.[lx.pos] else None
let skip lx = lx.pos <- lx.pos + 1
let wordchr c = not (String.contains " \t\n#;&|`'{}()<>^$" c)
let idchr c = c = '_' || ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9')
let while_ lx p = while (match peekc lx with Some c -> p c | None -> false) do skip lx done

let rec token lx : token =
  let op tok = skip lx; tok in
  let two c tok1 tok2 = skip lx; if peekc lx = Some c then op tok2 else tok1 in
  match peekc lx with
  | None -> EOF
  | Some (' ' | '\t') -> skip lx; token lx
  | Some '#' -> while_ lx (( <> ) '\n'); token lx
  | Some '\\' when lx.pos + 1 < String.length lx.text && lx.text.[lx.pos + 1] = '\n' ->
      lx.pos <- lx.pos + 2; token lx   (* a line continued *)
  | Some '\n' -> op NL | Some ';' -> op SEMI | Some '`' -> op BACKQ
  | Some '(' -> op LPAREN | Some ')' -> op RPAREN
  | Some '{' -> op LBRACE | Some '}' -> op RBRACE
  | Some '&' -> two '&' AMP ANDAND
  | Some '|' -> two '|' PIPE OROR
  | Some '<' -> skip lx; redir lx 0 Read
  | Some '>' -> skip lx; if peekc lx = Some '>' then (skip lx; redir lx 1 Append) else redir lx 1 Write
  | Some _ -> WORD (word lx)

(* <file >[2]file >[2=1] *)
and redir lx fd mode : token =
  let num () =
    let start = lx.pos in
    while_ lx (fun c -> '0' <= c && c <= '9');
    match int_of_string_opt (String.sub lx.text start (lx.pos - start)) with
    | Some n -> n | None -> raise (Error "bad redirection")
  in
  let file fd = match token lx with WORD w -> Open (fd, mode, w) | _ -> raise (Error "redirection without a file") in
  if peekc lx <> Some '[' then REDIR (file fd)
  else begin
    skip lx;
    let a = num () in
    if peekc lx = Some '=' then (skip lx; let b = num () in skip lx; REDIR (Dup (a, b)))
    else (skip lx; REDIR (file a))
  end

and word lx : word =
  let from start = String.sub lx.text start (lx.pos - start) in
  match peekc lx with
  | Some '\'' ->
      skip lx;
      let b = Buffer.create 16 in
      let rec quoted () =
        match peekc lx with
        | None -> raise (Error "eof in quotes")
        | Some '\'' -> skip lx; if peekc lx = Some '\'' then (skip lx; Buffer.add_char b '\''; quoted ())
        | Some c -> skip lx; Buffer.add_char b c; quoted ()
      in
      quoted ();
      let lit = Lit (Buffer.contents b, true) in
      lit :: more lx
  | Some '$' ->
      skip lx;
      let count = peekc lx = Some '#' in
      if count then skip lx;
      let start = lx.pos in
      if peekc lx = Some '*' then skip lx else while_ lx idchr;
      let var = if count then Count (from start) else Var (from start) in
      var :: more lx
  | Some '^' -> skip lx; more lx
  | _ ->
      let start = lx.pos in
      while_ lx wordchr;
      let lit = Lit (from start, false) in
      lit :: more lx

(* the pieces that follow with nothing between *)
and more lx = match peekc lx with Some c when wordchr c || String.contains "'$^" c -> word lx | _ -> []

(*****************************************************************************)
(* Parsing *)
(*****************************************************************************)

type parser = { lx : lexer; mutable ahead : token option }

let peek p = match p.ahead with Some t -> t | None -> let t = token p.lx in p.ahead <- Some t; t
let next p = let t = peek p in p.ahead <- None; t
let expect p t = if next p <> t then raise (Error "syntax error")
let rec skipnl p = if peek p = NL then (ignore (next p); skipnl p)
(* old: the keyword's string, matched as Some "if": a misspelling was
 * silently a command's name *)
let keyword p : [ `Bang | `At | `If | `While | `For | `In | `Fn ] option =
  match peek p with
  | WORD [ Lit (k, false) ] -> List.assoc_opt k [ "!", `Bang; "@", `At; "if", `If; "while", `While; "for", `For; "in", `In; "fn", `Fn ]
  | _ -> None
let name p what = match next p with WORD [ Lit (x, _) ] -> x | _ -> raise (Error (what ^ ": a name"))

(* x= at the start of a word: x, and what follows the = *)
let assignment (w : word) =
  match w with
  | Lit (s, false) :: rest -> (
      match String.index_opt s '=' with
      | Some i when i > 0 && String.for_all idchr (String.sub s 0 i) ->
          let v = String.sub s (i + 1) (String.length s - i - 1) in
          Some (String.sub s 0 i, if v = "" then rest else Lit (v, false) :: rest)
      | _ -> None)
  | _ -> None

(* commands separated by ; & and newlines, until [stop] *)
let rec body p stop : cmd =
  let c = and_or p in
  if stop (peek p) then c
  else
    let c = match next p with AMP -> Async c | SEMI | NL -> c | _ -> raise (Error "syntax error") in
    if stop (peek p) then c else Seq (c, body p stop)

and and_or p =
  let c = ref (pipe p) in
  while peek p = ANDAND || peek p = OROR do
    let t = next p in
    skipnl p;
    let right = pipe p in
    c := if t = ANDAND then And (!c, right) else Or (!c, right)
  done;
  !c

and pipe p =
  let c = ref (unit p) in
  while peek p = PIPE do ignore (next p); skipnl p; c := Pipe (!c, unit p) done;
  !c

and cond p = expect p LPAREN; let c = body p (( = ) RPAREN) in expect p RPAREN; skipnl p; c

and block p = expect p LBRACE; let c = body p (( = ) RBRACE) in expect p RBRACE; c

(* as in rc's grammar, ! and @ take a pipe, if while and for all the
 * rest *)
and unit p : cmd =
  let kw () = ignore (next p) in
  match keyword p, peek p with
  | Some `Bang, _ -> kw (); Not (pipe p)
  | Some `At, _ -> kw (); Subshell (pipe p)
  | Some `If, _ -> kw (); let c = cond p in If (c, and_or p)
  | Some `While, _ -> kw (); let c = cond p in While (c, and_or p)
  | Some `For, _ ->
      kw ();
      expect p LPAREN;
      let x = name p "for" in
      let list = if keyword p = Some `In then (ignore (next p); Some (words p)) else None in
      expect p RPAREN;
      skipnl p;
      For (x, list, and_or p)
  | Some `Fn, _ -> kw (); let f = name p "fn" in Fn (f, block p)
  | _, LBRACE -> let c = block p in Brace (c, redirs p)
  | _, WORD w when assignment w <> None ->
      ignore (next p);
      let x, v = Option.get (assignment w) in
      let value =
        match v, peek p with
        | [], LPAREN -> ignore (next p); let ws = words p in expect p RPAREN; ws
        | [], BACKQ -> [ one_word p ]
        | [], _ -> []
        | v, _ -> [ v ]
      in
      (match peek p with
       | WORD _ | BACKQ | REDIR _ | LBRACE -> Assign (x, value, Some (unit p))
       | _ -> Assign (x, value, None))
  | _, (WORD _ | BACKQ | REDIR _) ->
      let rec go ws rs =
        match peek p with
        | REDIR r -> ignore (next p); go ws (r :: rs)
        | WORD _ | BACKQ -> go (one_word p :: ws) rs
        | _ -> Simple (List.rev ws, List.rev rs)
      in
      go [] []
  | _ -> Empty

and redirs p = match peek p with REDIR r -> ignore (next p); r :: redirs p | _ -> []

(* a word; a `{cmd} is one *)
and one_word p = match next p with WORD w -> w | BACKQ -> [ Back (block p) ] | _ -> raise (Error "syntax error")

and words p = match peek p with WORD _ | BACKQ -> let w = one_word p in w :: words p | _ -> []

(*****************************************************************************)
(* Matching and globbing *)
(*****************************************************************************)

(* in a word being built, a character not to glob has a \000 before it *)
let escape s =
  if not (String.exists (fun c -> String.contains "*?[\000" c) s) then s
  else String.concat "" (List.map (fun c -> (if String.contains "*?[\000" c then "\000" else "") ^ String.make 1 c)
                           (List.of_seq (String.to_seq s)))

let unescape s =
  let b = Buffer.create (String.length s) and esc = ref false in
  String.iter (fun c -> if c = '\000' && not !esc then esc := true else (esc := false; Buffer.add_char b c)) s;
  Buffer.contents b

let rec has_meta s i =
  i < String.length s && (if s.[i] = '\000' then has_meta s (i + 2) else String.contains "*?[" s.[i] || has_meta s (i + 1))

(* [matches pat s]: * ? [a-z] [~a-z], on an escaped pattern *)
let matches (pat : string) (s : string) : bool =
  let n = String.length pat and m = String.length s in
  let rec go i j =
    if i = n then j = m
    else match pat.[i] with
      | '*' -> go (i + 1) j || (j < m && go i (j + 1))
      | '?' -> j < m && go (i + 1) (j + 1)
      | '[' when j < m && String.index_from_opt pat (min (i + 2) n) ']' <> None ->
          let close = String.index_from pat (i + 2) ']' in
          let neg = pat.[i + 1] = '~' in
          let rec member k =
            k < close
            && (if k + 2 < close && pat.[k + 1] = '-' then (pat.[k] <= s.[j] && s.[j] <= pat.[k + 2]) || member (k + 3)
                else pat.[k] = s.[j] || member (k + 1))
          in
          member (if neg then i + 2 else i + 1) <> neg && go (close + 1) (j + 1)
      | '\000' when i + 1 < n -> j < m && pat.[i + 1] = s.[j] && go (i + 2) (j + 1)
      | c -> j < m && c = s.[j] && go (i + 1) (j + 1)
  in
  go 0 0

(* the files a pattern names, sorted, a component at a time; the
 * pattern itself when there are none *)
let glob (w : string) : string list =
  let rec expand dir = function
    | [] -> [ dir ]
    | comp :: rest when not (has_meta comp 0) -> expand (dir ^ unescape comp ^ if rest = [] then "" else "/") rest
    | comp :: rest ->
        let entries = try Sys.readdir (if dir = "" then "." else dir) with Sys_error _ -> [||] in
        Array.sort compare entries;
        entries |> Array.to_list
        |> List.filter (matches comp)
        |> List.concat_map (fun e ->
            if rest = [] then [ dir ^ e ] else if Sys.is_directory (dir ^ e) then expand (dir ^ e ^ "/") rest else [])
  in
  if not (has_meta w 0) then [ unescape w ]
  else
    let comps = List.filter (( <> ) "") (String.split_on_char '/' w) in
    match expand (if w.[0] = '/' then "/" else "") comps with [] -> [ unescape w ] | l -> l

(*****************************************************************************)
(* Variables and statuses *)
(*****************************************************************************)

let vars : (string, string list) Hashtbl.t = Hashtbl.create 64
let fns : (string, cmd) Hashtbl.t = Hashtbl.create 16

let get x =
  let find x = Option.value (Hashtbl.find_opt vars x) ~default:[] in
  match int_of_string_opt x with
  | Some n when n > 0 -> (match List.nth_opt (find "*") (n - 1) with Some v -> [ v ] | None -> [])
  | _ -> find x

let set x v = if v = [] then Hashtbl.remove vars x else Hashtbl.replace vars x v
let status () = String.concat "" (get "status")
let set_status s = set "status" [ s ]

(* [local x v f]: f with x set to v, then x as it was *)
let local x v f =
  let old = get x in
  set x v;
  Fun.protect f ~finally:(fun () -> set x old)

(* true when all its parts are: "", "0|", "|" *)
let truth s = String.for_all (fun c -> c = '0' || c = '|') s

(* an exit code: rc's, the leading number, or 1 *)
let code s =
  if truth s then 0
  else match int_of_string_opt (List.hd (String.split_on_char '|' s)) with Some n when n > 0 -> n | _ -> 1

let describe = function
  | Unix.WEXITED 0 -> ""
  | Unix.WEXITED n -> string_of_int n
  | Unix.WSIGNALED n | Unix.WSTOPPED n -> "signal " ^ string_of_int n

(*****************************************************************************)
(* Processes and fds *)
(*****************************************************************************)

let rec wait (caps : < Cap.wait; .. >) pid =
  try describe (snd (CapUnix.waitpid caps [] pid)) with Unix.Unix_error (Unix.EINTR, _, _) -> wait caps pid

let die m = prerr_endline ("tinyshell: " ^ m); "error"

(* f in a child, which exits with the status it leaves *)
let fork (caps : < Cap.fork; .. >) (f : unit -> unit) : int =
  flush_all ();
  match CapUnix.fork caps () with
  | 0 ->
      let st = try f (); status () with Exit s -> s | Error m -> die m in
      flush_all ();
      Unix._exit (code st)
  | pid -> pid

(* lists, rc's way: joined by \001 *)
let environment () =
  Hashtbl.fold (fun x v acc -> if x = "*" then acc else (x ^ "=" ^ String.concat "\001" v) :: acc) vars []
  |> Array.of_list

let exec (caps : < Cap.exec; .. >) (argv : string list) =
  let name = List.hd argv in
  let files =
    if String.contains name '/' then [ name ]
    else List.map (fun d -> Filename.concat d name) (String.split_on_char ':' (String.concat "" (get "PATH")))
  in
  let why = List.fold_left (fun _ f ->
      try CapUnix.execve caps f (Array.of_list argv) (environment ()); ""
      with Unix.Unix_error (e, _, _) -> Unix.error_message e) "not found" files in
  prerr_endline (name ^ ": " ^ why);
  Unix._exit 1

let fd (n : int) : Unix.file_descr = Obj.magic n

(* [with_fds changes f]: each fd changed (the file, or another fd), f
 * run, then each fd put back *)
let with_fds (changes : (int * [ `File of string * mode | `Fd of int ]) list) f =
  flush_all ();
  let saved = List.map (fun (n, _) -> n, try Some (Unix.dup ~cloexec:true (fd n)) with Unix.Unix_error _ -> None) changes in
  let restore () =
    flush_all ();
    List.rev saved |> List.iter (fun (n, s) ->
      match s with Some s -> Unix.dup2 s (fd n); Unix.close s | None -> Unix.close (fd n))
  in
  let change (n, to_) =
    match to_ with
    | `Fd m -> Unix.dup2 (fd m) (fd n)
    | `File (file, mode) ->
        let flags = match mode with Read -> [ Unix.O_RDONLY ] | Write -> Unix.[ O_WRONLY; O_CREAT; O_TRUNC ] | Append -> Unix.[ O_WRONLY; O_CREAT; O_APPEND ] in
        let f = try Unix.openfile file (Unix.O_CLOEXEC :: flags) 0o666
          with Unix.Unix_error (e, _, _) -> raise (Error (file ^ ": " ^ Unix.error_message e)) in
        Unix.dup2 f (fd n);
        Unix.close f
  in
  match List.iter change changes with
  | () -> Fun.protect f ~finally:restore
  | exception e -> restore (); raise e

(* [into w f]: f in a child whose standard output is w *)
let into caps w r f = fork caps (fun () -> Unix.dup2 w Unix.stdout; Unix.close w; Unix.close r; f ())

(*****************************************************************************)
(* Evaluation *)
(*****************************************************************************)

let background = ref []
let eflag = ref false

(* a list joined to another: distributing, or pairwise *)
let join (a : string list) (b : string list) : string list =
  match a, b with
  | [], _ | _, [] -> raise (Error "null list in concatenation")
  | [ x ], l -> List.map (fun y -> x ^ y) l
  | l, [ y ] -> List.map (fun x -> x ^ y) l
  | l1, l2 when List.length l1 = List.length l2 -> List.map2 ( ^ ) l1 l2
  | _ -> raise (Error "mismatched list lengths in concatenation")

(* e: -e applies here, not in a condition *)
(* old: a global count of the conditions being run, still raised in a
 * function called from one: its failures were ignored *)
let rec run (caps : caps) ~e (c : cmd) : unit =
  let run = run caps ~e and cond = run caps ~e:false and words = words caps in
  match c with
  | Empty -> ()
  | Seq (a, b) -> run a; run b
  | Async c ->
      let pid = fork caps (fun () -> run c) in
      background := pid :: !background;
      set "apid" [ string_of_int pid ]
  | And (a, b) -> cond a; if truth (status ()) then run b
  | Or (a, b) -> cond a; if not (truth (status ())) then run b
  | Not c -> cond c; set_status (if truth (status ()) then "false" else "")
  | If (c, body) -> cond c; if truth (status ()) then run body
  | While (c, body) ->
      let rec loop () = cond c; if truth (status ()) then (run body; loop ()) in
      loop ()
  | For (x, list, body) ->
      List.iter (fun v -> set x [ v ]; run body) (match list with Some ws -> words ws | None -> get "*")
  | Fn (f, body) -> Hashtbl.replace fns f body
  | Assign (x, v, None) -> set x (words v)
  | Assign (x, v, Some c) -> local x (words v) (fun () -> run c)
  | Brace (c, rs) -> with_fds (redirs caps rs) (fun () -> run c)
  | Subshell c -> set_status (wait caps (fork caps (fun () -> run c))); check ~e
  | Pipe (a, b) ->
      let r, w = Unix.pipe ~cloexec:true () in
      let pid = into caps w r (fun () -> run a) in
      Unix.close w;
      let saved = Unix.dup ~cloexec:true Unix.stdin in
      Unix.dup2 r Unix.stdin;
      Unix.close r;
      Fun.protect (fun () -> run b) ~finally:(fun () -> flush_all (); Unix.dup2 saved Unix.stdin; Unix.close saved);
      let last = status () in
      set_status (wait caps pid ^ "|" ^ last);
      check ~e
  | Simple ([ Lit ("~", false) ] :: args, rs) ->
      (* ~ subject pattern ...: the words as they are, not globbed *)
      with_fds (redirs caps rs) (fun () ->
        match List.concat_map (word caps) args with
        | subject :: pats -> set_status (if List.exists (fun p -> matches p (unescape subject)) pats then "" else "no match")
        | [] -> set_status "no match")
  | Simple (ws, rs) ->
      let argv = words ws in
      with_fds (redirs caps rs) (fun () -> command caps argv);
      check ~e

and check ~e = if !eflag && e && not (truth (status ())) then raise (Exit (status ()))

and command caps (argv : string list) =
  match argv with
  | [] -> ()
  (* a function's body is no condition, even called from one *)
  | f :: args when Hashtbl.mem fns f -> local "*" args (fun () -> run caps ~e:true (Hashtbl.find fns f))
  | [ "cd" ] | [ "cd"; _ ] ->
      let dir = match argv with [ _; d ] -> d | _ -> String.concat "" (get "HOME") in
      (try CapUnix.chdir caps dir; set_status ""
       with Unix.Unix_error (e, _, _) -> prerr_endline ("Can't cd " ^ dir ^ ": " ^ Unix.error_message e); set_status "can't cd")
  | "exit" :: args -> raise (Exit (match args with s :: _ -> s | [] -> status ()))
  | [ "shift" ] | [ "shift"; _ ] ->
      let n = match argv with [ _; n ] -> Option.value (int_of_string_opt n) ~default:1 | _ -> 1 in
      set "*" (List.filteri (fun i _ -> i >= n) (get "*"));
      set_status ""
  | [ "wait" ] ->
      List.iter (fun pid -> set_status (wait caps pid)) (List.rev !background);
      background := []
  | _ -> set_status (wait caps (fork caps (fun () -> exec caps argv)))

and redirs caps rs =
  rs |> List.map (function
    | Dup (a, b) -> a, `Fd b
    | Open (n, mode, w) -> (
        match words caps [ w ] with
        | [ file ] -> n, `File (file, mode)
        | _ -> raise (Error "a redirection needs one file")))

(* a word's values, escaped where not to glob *)
and word caps (w : word) : string list =
  let piece = function
    | Lit (s, quoted) -> [ if quoted then escape s else s ]
    | Var x -> List.map escape (get x)
    | Count x -> [ string_of_int (List.length (get x)) ]
    | Back c ->
        let r, w = Unix.pipe ~cloexec:true () in
        let pid = into caps w r (fun () -> run caps ~e:true c) in
        Unix.close w;
        let ic = Unix.in_channel_of_descr r in
        let out = In_channel.input_all ic in
        close_in ic;
        set_status (wait caps pid);
        String.split_on_char '\n' out |> List.concat_map (String.split_on_char ' ')
        |> List.concat_map (String.split_on_char '\t') |> List.filter (( <> ) "") |> List.map escape
  in
  match w with
  | [] -> []
  | first :: rest -> List.fold_left (fun acc p -> join acc (piece p)) (piece first) rest

and words caps (ws : word list) : string list = List.concat_map (fun w -> List.concat_map glob (word caps w)) ws

(*****************************************************************************)
(* Main *)
(*****************************************************************************)

(* the commands of a text, each run once it is read *)
let source caps (text : string) =
  let p = { lx = { text; pos = 0 }; ahead = None } in
  let rec loop () =
    skipnl p;
    if peek p <> EOF then (run caps ~e:true (body p (fun t -> t = NL || t = EOF)); loop ())
  in
  loop ()

let main (caps : Cap.all_caps) : int =
  (* the environment, with rc's lists split back *)
  CapUnix.environment caps () |> Array.iter (fun kv ->
    match String.index_opt kv '=' with
    | Some i -> set (String.sub kv 0 i) (String.split_on_char '\001' (String.sub kv (i + 1) (String.length kv - i - 1)))
    | None -> ());
  set "pid" [ string_of_int (Unix.getpid ()) ];
  let rec flags = function
    | a :: rest when String.length a > 1 && a.[0] = '-' && String.for_all (fun c -> String.contains "-eIi" c) a ->
        if String.contains a 'e' then eflag := true;
        flags rest
    | "-c" :: cmd :: args -> set "*" args; cmd
    | file :: args -> set "*" args; In_channel.with_open_bin file In_channel.input_all
    | [] -> In_channel.input_all stdin
  in
  let st =
    try
      source (caps :> caps) (flags (List.tl (Array.to_list (CapSys.argv caps))));
      status ()
    with Exit s -> s | Error m -> die m | Sys_error m -> die m
  in
  flush_all ();
  code st

let () = Cap.main (fun caps -> CapStdlib.exit caps (main caps))
