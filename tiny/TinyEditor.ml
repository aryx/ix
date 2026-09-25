(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* A tiny editor, in one file, in sam's command language rather than
 * ed's. mini-ed (editor/) is ed, faithfully: a buffer of lines, commands on
 * line ranges, g to loop over lines. This is what Rob Pike made of ed
 * in sam ("The Text Editor sam", "Structural Regular Expressions",
 * 1987), without the screen:
 *
 *     ,x/o/c/0/              every o in the file changed to 0
 *     ,x/.*\n/g/TODO/p       the lines with a TODO, printed
 *     /main/;/^}/d           from the next main to the } that ends it
 *     ,y/\n/ s/^/  /         ... (y: the text between the matches)
 *     #10,#20p  3,5p  $p     characters 10 to 20, lines 3 to 5, the end
 *
 * What makes it sam's, and why it is the core:
 *
 * - {b The buffer is one string, and dot is a range of characters}, not
 *   a line. A line is one address among others: 3 is the range of the
 *   third line, newline included; #10 the empty range before character
 *   10; /re/ the next match, wrapping; a,b from the start of a to the
 *   end of b; a;b the same, with dot set to a before b is evaluated.
 * - {b Loops are commands over matches}: x/re/cmd runs cmd with dot on
 *   each match of re in dot, y/re/cmd on the text between them, and
 *   g/re/cmd and v/re/cmd run cmd, or not, on dot as a whole. So ed's
 *   g/re/s/a/b/ is ,x/.*\n/g/re/s/a/b/, and the loops nest.
 * - {b Changes are made in parallel}: a command (with its loops) only
 *   records its changes, against the text as it was when it started,
 *   and they are applied together at the end. So every address and
 *   every match in a loop sees the old text, and the changes must come
 *   in order, not overlapping ("changes not in sequence" otherwise).
 *
 * The commands: a i c (/text/, or lines until "."), d, s/re/text/ (sN,
 * g, & and \1-\9), m and t, p, = and =#, x y g v, { }, r w e f q, and
 * a newline, which prints the next line. Dropped from sam: the screen,
 * several files (b B D n X Y, and addresses naming a file), u, the
 * mark (k and its address), ! < > |,
 * cd. Where sam's dot after a loop or a move is odd (the first change's
 * range after an x, an empty range after t), dot is here simply the
 * text the command made. The matcher is a small backtracker, leftmost-
 * longest like sam's, with a memo of (node, position) pairs; libregexp's
 * answers differ from it in corner cases (mini-ed's Regex.mli).
 *
 * Exercises, each cheap because a command's changes are a list, made
 * against the old text and applied together:
 * - undo (sam's u): keep, for each change applied, the text it
 *   replaced; the list of those, reversed, is the command's inverse,
 *   applied the same way; u n undoes n commands;
 * - several files: a buffer and a dot per file, the addresses naming a
 *   file ("name"), X/re/cmd and Y running cmd in each file whose name
 *   matches, or not (sam's);
 * - | < > (sam's): dot sent to a command, or replaced by its output, or
 *   both; a change like any other, so it composes with x;
 * - the buffer as a piece table (Bravo's, then Word's), or a rope: a
 *   change no longer copies the whole text, and undo keeps the old
 *   pieces for nothing;
 * - dots, not a dot: the matches of an x kept as a set of selections,
 *   and the next command run on each (Kakoune's and vis's editing
 *   model, grown from sam's x).
 *
 * The test: test.sh runs scripts through it and through 9base's sam -d.
 *
 * Usage: tiny-editor [file] -- the commands on standard input
 *
 * References: Rob Pike, "The Text Editor sam" (Software -- Practice and
 * Experience, 1987), for the command language, the addresses as
 * character ranges, and a command's changes applied together at its
 * end; Rob Pike, "Structural Regular Expressions" (EUUG, 1987), for x
 * and y, loops over the matches rather than over lines -- ed's g
 * turned into one loop among others; C. Crowley, "Data Structures for
 * Text Sequences" (1998; from memory), the piece table; H. Boehm, R.
 * Atkinson, M. Plass, "Ropes: an Alternative to Strings" (Software --
 * Practice and Experience, 1995; from memory). *)

(*****************************************************************************)
(* Regular expressions *)
(*****************************************************************************)

type re = { id : int; kind : kind }

and kind =
  | Chr of char
  | Any
  | Set of bool * (char * char) list   (* negated, and its ranges *)
  | Bol
  | Eol
  | Cat of re * re
  | Alt of re * re
  | Star of re
  | Group of int * re
  | Empty

exception Error of string

(* Plan 9's notation, as ed and sam have it; \n is a newline *)
let parse_re (p : string) : re * int =
  let pos = ref 0 and ids = ref 0 and groups = ref 0 and after = ref ' ' in
  let mk kind = incr ids; { id = !ids - 1; kind } in
  let peek () = if !pos < String.length p then Some p.[!pos] else None in
  let next () =
    let c = p.[!pos] in
    incr pos;
    if c = '\\' && !pos < String.length p then (incr pos; `Quoted (match p.[!pos - 1] with 'n' -> '\n' | c -> c))
    else `Plain c
  in
  let rec alt () =
    let a = cat () in
    if peek () = Some '|' then (incr pos; after := '|'; mk (Alt (a, alt ()))) else a
  and cat () =
    let a = rep () in
    match peek () with None | Some ('|' | ')') -> a | _ -> mk (Cat (a, cat ()))
  and rep () =
    let rec go a =
      match peek () with
      | Some '*' -> incr pos; go (mk (Star a))
      | Some '+' -> incr pos; go (mk (Cat (a, mk (Star (copy a)))))
      | Some '?' -> incr pos; go (mk (Alt (a, mk Empty)))
      | _ -> a
    in
    go (atom ())
  (* sam's messages: the operator an operand is missing for *)
  and atom () =
    let missing c = raise (Error (Printf.sprintf "no operand for `%c'" c)) in
    if !pos >= String.length p then missing !after;
    match next () with
    | `Quoted c -> mk (Chr c)
    | `Plain '.' -> mk Any
    | `Plain '^' -> mk Bol
    | `Plain '$' -> mk Eol
    | `Plain '(' ->
        incr groups;
        after := '(';
        let g = !groups in
        let e = alt () in
        if peek () <> Some ')' then raise (Error "unmatched `('");
        incr pos;
        mk (Group (g, e))
    | `Plain '[' ->
        let neg = peek () = Some '^' in
        if neg then incr pos;
        let rec ranges acc =
          if !pos >= String.length p then raise (Error "malformed `[]'");
          match next () with
          | `Plain ']' when acc <> [] -> List.rev acc
          | `Plain c | `Quoted c ->
              if peek () = Some '-' && !pos + 1 < String.length p && p.[!pos + 1] <> ']' then begin
                incr pos;
                match next () with `Plain d | `Quoted d -> ranges ((c, d) :: acc)
              end
              else ranges ((c, c) :: acc)
        in
        mk (Set (neg, ranges []))
    | `Plain (('*' | '+' | '?') as c) -> missing c
    | `Plain ('|' | ')') -> missing !after
    | `Plain c -> mk (Chr c)
  and copy n =
    mk (match n.kind with
      | Cat (a, b) -> Cat (copy a, copy b)
      | Alt (a, b) -> Alt (copy a, copy b)
      | Star a -> Star (copy a)
      | Group (g, a) -> Group (g, copy a)
      | k -> k)
  in
  let r = alt () in
  if !pos < String.length p then raise (Error "unmatched `)'");
  r, !ids

(* [ends re text s lim k]: k end captures, for each way re matches
 * text from s, ending by lim, in priority order; a (node, position)
 * pair is tried once (a second visit could only find the same ends) *)
let ends (re, size) (text : string) (s : int) (lim : int) (k : int -> int array -> unit) =
  let seen = Bytes.make (size * (lim - s + 1)) '\000' in
  let caps = Array.make 20 (-1) in
  let rec m n i k =
    let key = (n.id * (lim - s + 1)) + (i - s) in
    if Bytes.get seen key = '\000' then begin
      Bytes.set seen key '\001';
      match n.kind with
      | Chr c -> if i < lim && text.[i] = c then k (i + 1)
      | Any -> if i < lim && text.[i] <> '\n' then k (i + 1)
      | Set (neg, rs) ->
          if i < lim && text.[i] <> '\n' && List.exists (fun (a, b) -> a <= text.[i] && text.[i] <= b) rs <> neg then k (i + 1)
      | Bol -> if i = 0 || text.[i - 1] = '\n' then k i
      | Eol -> if i = String.length text || text.[i] = '\n' then k i
      | Empty -> k i
      | Cat (a, b) -> m a i (fun j -> m b j k)
      | Alt (a, b) -> m a i k; m b i k
      | Star a -> m a i (fun j -> m n j k); k i
      | Group (g, a) ->
          let o = caps.(2 * g) in
          caps.(2 * g) <- i;
          m a i (fun j -> let e = caps.((2 * g) + 1) in caps.((2 * g) + 1) <- j; k j; caps.((2 * g) + 1) <- e);
          caps.(2 * g) <- o
    end
  in
  m re s (fun j -> caps.(0) <- s; caps.(1) <- j; k j caps)

(* the longest match starting at s *)
let longest re text s lim =
  let best = ref None in
  ends re text s lim (fun j caps -> match !best with Some (e, _) when e >= j -> () | _ -> best := Some (j, Array.copy caps));
  Option.map snd !best

(* the leftmost-longest match starting in [p, lim] *)
let rec search re text p lim = if p > lim then None else match longest re text p lim with Some c -> Some c | None -> search re text (p + 1) lim

(* backwards from p: the match ending nearest before p, then the
 * longest of those *)
let search_back re text p =
  let best = ref None in
  for s = 0 to p do
    ends re text s p (fun j caps ->
      match !best with
      | Some b when b.(1) > j || (b.(1) = j && b.(0) <= s) -> ()
      | _ -> best := Some (Array.copy caps))
  done;
  !best

(*****************************************************************************)
(* Commands *)
(*****************************************************************************)

(* #n n /re/ ?re? . $ *)
type simple = Chars of int | Line of int | Search of dir * string | Dot | Dollar
and dir = Fwd | Back

(* a first simple address, then steps each relative to the one before
 * in its direction; a step without an address is a line: 3+/re/-, -2 *)
type chain = { first : simple option; steps : (dir * simple option) list }

(* a,b and a;b (b from a), right to left: a,b,c is a,(b,c) *)
(* old: sam's C list, simple addresses and Rel markers in one list, a +
 * inserted between two addresses by the parser (under a guard), the
 * direction an int carried along, and a look ahead in the evaluator to
 * know if a sign stood alone; , and ; were chars, compared twice *)
type addr = Chain of chain | Range of sep * chain option * addr option
and sep = Comma | Semi

type cmd = { addr : addr option; op : op }

and op =
  | Text of where * string         (* a i c *)
  | Delete
  | Subst of int * string * string * bool
  | Print
  | Eq of bool                     (* =, =# *)
  | Move of bool * chain          (* m, or t *)
  | Loop of loop * cmd
  | Block of cmd list
  | File of file * string
  | Quit
  | Newline

(* where a, i and c put their text: after, before or instead of dot *)
and where = After | Before | Instead

(* x alone (each line), x/re/ (each match), y/re/ (between them), g/re/
 * and v/re/ (if dot matches, or not) *)
(* old: Loop of char * string option * cmd: a y without a pattern could
 * be built, and ran as x does, where sam refuses it *)
and loop = Lines | Matches of string | Between of string | If of bool * string

(* r w e f *)
(* old: File of char * string, whose last case, a catch-all, stood for f *)
and file = Read | Write | Edit | Name

(* the input, one character of pushback *)
let input = ref "" and ip = ref 0
let peekc () = if !ip < String.length !input then !input.[!ip] else '\000'
let getc () = let c = peekc () in incr ip; c
let skipbl () = while peekc () = ' ' || peekc () = '\t' do incr ip done; peekc ()
let atnl () = if skipbl () <> '\n' && peekc () <> '\000' then raise (Error "newline expected") else incr ip
let num () = let s = !ip in while peekc () >= '0' && peekc () <= '9' do incr ip done; if !ip = s then 1 else int_of_string (String.sub !input s (!ip - s))

let lastpat = ref ""

(* a /re/, up to the delimiter or the end of the line; empty: the last *)
let regexp delim =
  let b = Buffer.create 16 in
  let rec go () =
    match getc () with
    | '\\' when peekc () = delim -> Buffer.add_char b (getc ()); go ()
    | '\\' -> Buffer.add_char b '\\'; Buffer.add_char b (getc ()); go ()
    | c when c = delim -> ()
    | '\n' | '\000' -> decr ip
    | c -> Buffer.add_char b c; go ()
  in
  go ();
  if Buffer.length b > 0 then lastpat := Buffer.contents b;
  if !lastpat = "" then raise (Error "no pattern");
  !lastpat

(* a replacement or a text: \n is a newline, \ then the delimiter the
 * delimiter; s keeps its other \s, for \1 *)
let rhs delim ~s =
  let b = Buffer.create 16 in
  let rec go () =
    match getc () with
    | '\\' ->
        (match getc () with
         | 'n' -> Buffer.add_char b '\n'
         | c when c = delim -> Buffer.add_char b c
         | c -> if s || c <> '\\' then Buffer.add_char b '\\'; Buffer.add_char b c);
        go ()
    | c when c = delim || c = '\n' || c = '\000' -> decr ip
    | c -> Buffer.add_char b c; go ()
  in
  go ();
  Buffer.contents b

let simple () : simple option =
  match skipbl () with
  | '#' -> incr ip; Some (Chars (num ()))
  | '0' .. '9' -> Some (Line (num ()))
  | ('/' | '?') as c -> incr ip; Some (Search ((if c = '/' then Fwd else Back), regexp c))
  | '.' -> incr ip; Some Dot
  | '$' -> incr ip; Some Dollar
  | _ -> None

let chain () : chain option =
  (* . and $ only first *)
  let later s = match s with Some (Dot | Dollar) -> raise (Error "address") | _ -> s in
  let first = simple () in
  let rec steps () =
    match skipbl () with
    | '+' -> incr ip; let s = later (simple ()) in (Fwd, s) :: steps ()
    | '-' -> incr ip; let s = later (simple ()) in (Back, s) :: steps ()
    (* 3/re/ is 3+/re/: the + is implied *)
    | _ -> (match later (simple ()) with Some s -> (Fwd, Some s) :: steps () | None -> [])
  in
  match first, steps () with
  | None, [] -> None
  | first, steps -> Some { first; steps }

let rec compound () : addr option =
  let left = chain () in
  match skipbl () with
  | ',' -> incr ip; Some (Range (Comma, left, compound ()))
  | ';' -> incr ip; Some (Range (Semi, left, compound ()))
  | _ -> Option.map (fun c -> Chain c) left

let rec parse () : cmd option =
  let addr = compound () in
  if skipbl () = '\000' then None
  else
    let c = getc () in
    let delim () =
      match skipbl () with
      | '\n' | '\000' -> raise (Error "no pattern")
      | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9') as c -> raise (Error (Printf.sprintf "bad delimiter `%c'" c))
      | _ -> getc ()
    in
    let text () =
      if skipbl () = '\n' then begin
        (* lines until "." *)
        incr ip;
        let b = Buffer.create 64 in
        let rec lines () =
          let e = match String.index_from_opt !input !ip '\n' with Some e -> e | None -> String.length !input in
          let l = String.sub !input !ip (e - !ip) in
          ip := e + 1;
          if l <> "." && !ip <= String.length !input + 1 && e < String.length !input then (Buffer.add_string b l; Buffer.add_char b '\n'; lines ())
        in
        lines ();
        Buffer.contents b
      end
      else (let d = getc () in let t = rhs d ~s:false in if peekc () = d then incr ip; atnl (); t)
    in
    let word () = ignore (skipbl ()); let s = !ip in while peekc () <> '\n' && peekc () <> '\000' do incr ip done; let w = String.sub !input s (!ip - s) in atnl (); String.trim w in
    let sub () = match skipbl () with '\n' -> incr ip; { addr = None; op = Print } | _ -> Option.get (parse ()) in
    let op =
      match c with
      | 'a' -> Text (After, text ())
      | 'i' -> Text (Before, text ())
      | 'c' -> Text (Instead, text ())
      | 'd' -> atnl (); Delete
      | 's' ->
          let n = num () in
          let d = delim () in
          let re = regexp d in
          let t = rhs d ~s:true in
          let g = if peekc () = d then (incr ip; if peekc () = 'g' then (incr ip; true) else false) else false in
          atnl ();
          Subst (n, re, t, g)
      | 'p' -> atnl (); Print
      | '=' -> let chars = peekc () = '#' in if chars then incr ip; atnl (); Eq chars
      | 'm' | 't' -> (match chain () with Some a -> atnl (); Move (c = 'm', a) | None -> raise (Error "address"))
      | 'x' when (let n = peekc () in n = ' ' || n = '\t' || n = '\n') -> Loop (Lines, sub ())
      | 'x' | 'y' | 'g' | 'v' ->
          let re = regexp (delim ()) in
          let loop = match c with 'x' -> Matches re | 'y' -> Between re | _ -> If (c = 'g', re) in
          Loop (loop, sub ())
      | '{' ->
          let rec cmds acc =
            if skipbl () = '\n' then incr ip;
            if skipbl () = '}' then (incr ip; atnl (); List.rev acc)
            else match parse () with Some c -> cmds (c :: acc) | None -> raise (Error "missing }")
          in
          Block (cmds [])
      | 'r' -> File (Read, word ())
      | 'w' -> File (Write, word ())
      | 'e' -> File (Edit, word ())
      | 'f' -> File (Name, word ())
      | 'q' -> atnl (); Quit
      | '\n' -> Newline
      | c -> raise (Error (Printf.sprintf "unknown command `%c'" c))
    in
    Some { addr; op }

(*****************************************************************************)
(* The buffer, and changes made in parallel *)
(*****************************************************************************)

let text = ref "" and dot = ref (0, 0) and file = ref "" and modified = ref false and warned = ref false
let changes : (int * int * string) list ref = ref []   (* reversed *)
let hi = ref 0      (* the changes so far end here: the next must not start before *)

let change p0 p1 s =
  if p0 < !hi then raise (Error "changes not in sequence");
  if p0 < p1 || s <> "" then changes := (p0, p1, s) :: !changes;
  hi := p1

(* the changes applied; a position of the old text in the new one *)
let apply () =
  let cs = List.rev !changes in
  if cs <> [] then begin
    let b = Buffer.create (String.length !text) and at = ref 0 in
    List.iter (fun (p0, p1, s) -> Buffer.add_string b (String.sub !text !at (p0 - !at)); Buffer.add_string b s; at := p1) cs;
    Buffer.add_string b (String.sub !text !at (String.length !text - !at));
    text := Buffer.contents b;
    modified := true;
    warned := false
  end;
  changes := [];
  hi := 0

(* where old position p is after the changes before it *)
let shift p = List.fold_left (fun q (p0, p1, s) -> if p1 <= p then q + String.length s - (p1 - p0) else q) p !changes

let compile p = parse_re p

(*****************************************************************************)
(* Addresses *)
(*****************************************************************************)

let len () = String.length !text

(* address.c's lineaddr: line n, relative to (q0, q1) in direction sign *)
let lineaddr n (q0, q1) sign =
  let t = !text and nc = len () in
  if sign >= 0 then begin
    if n = 0 && (sign = 0 || q1 = 0) then (0, 0)
    else begin
      let p = ref 0 and start = ref 0 in
      if n = 0 then (start := q1; p := q1 - 1)
      else begin
        let k = ref 1 in
        if not (sign = 0 || q1 = 0) then (p := q1 - 1; k := (if t.[!p] = '\n' then 1 else 0); incr p);
        while !k < n do
          if !p >= nc then raise (Error "address range");
          if t.[!p] = '\n' then incr k;
          incr p
        done;
        start := !p
      end;
      (* to the end of that line, its newline included *)
      while !p < nc && (let c = t.[!p] in incr p; c <> '\n') do () done;
      (!start, !p)
    end
  end
  else begin
    let p = ref q0 and e = ref q0 in
    if n > 0 then begin
      let k = ref 0 in
      while !k < n do
        if !p = 0 then (incr k; if !k <> n then raise (Error "address range"))
        else if t.[!p - 1] <> '\n' || (incr k; !k <> n) then decr p
      done;
      e := !p;
      if !p > 0 then decr p
    end;
    while !p > 0 && t.[!p - 1] <> '\n' do decr p done;
    (!p, !e)
  end

(* nextmatch: a search from p, wrapping; an empty match right at p is
 * skipped *)
let next_match pat (q0, q1) forward =
  let re = compile pat in
  let t = !text in
  if forward then begin
    let find p = match search re t p (len ()) with Some c -> Some c | None -> search re t 0 (len ()) in
    match find q1 with
    | None -> raise (Error "search")
    | Some c when c.(0) = c.(1) && c.(0) = q1 -> (match find (if q1 + 1 > len () then 0 else q1 + 1) with Some c -> (c.(0), c.(1)) | None -> raise (Error "search"))
    | Some c -> (c.(0), c.(1))
  end
  else begin
    let find p = match search_back re t p with Some c -> Some c | None -> search_back re t (len ()) in
    match find q0 with
    | None -> raise (Error "search")
    | Some c when c.(0) = c.(1) && c.(1) = q0 -> (match find (if q0 - 1 < 0 then len () else q0 - 1) with Some c -> (c.(0), c.(1)) | None -> raise (Error "search"))
    | Some c -> (c.(0), c.(1))
  end

(* address.c's address(): a simple address, absolute (sign 0) or
 * relative to a in a direction (1 or -1) *)
let simple_address (s : simple) (a : int * int) (sign : int) : int * int =
  match s with
  | Chars n ->
      let q0, q1 = a in
      let r = if sign = 0 then (n, n) else if sign < 0 then (q0 - n, q0 - n) else (q1 + n, q1 + n) in
      if fst r < 0 || snd r > len () then raise (Error "address range");
      r
  | Line n -> lineaddr n a sign
  | Search (d, pat) -> next_match pat a (if d = Fwd then sign >= 0 else sign < 0)
  | Dot -> !dot
  | Dollar -> (len (), len ())

let chain_address (c : chain) (a : int * int) : int * int =
  let a = match c.first with Some s -> simple_address s a 0 | None -> a in
  List.fold_left (fun a (d, s) ->
    let sign = if d = Fwd then 1 else -1 in
    match s with Some s -> simple_address s a sign | None -> lineaddr 1 a sign) a c.steps

let rec address (ad : addr) (a : int * int) : int * int =
  match ad with
  | Chain c -> chain_address c a
  | Range (sep, l, r) ->
      let a1 = match l with Some l -> chain_address l a | None -> (0, 0) in
      if sep = Semi then dot := a1;
      let a2 = match r with Some r -> address r (if sep = Semi then a1 else a) | None -> (len (), len ()) in
      if snd a2 < fst a1 then raise (Error "address order");
      (fst a1, snd a2)

(*****************************************************************************)
(* Running commands *)
(*****************************************************************************)

let out = Buffer.create 4096
let flush () = print_string (Buffer.contents out); Buffer.clear out; flush stdout

let print_posn (q0, q1) chars =
  let t = !text in
  let count a b = let n = ref 0 in for i = a to b - 1 do if t.[i] = '\n' then incr n done; !n in
  if not chars then begin
    let l1 = 1 + count 0 q0 in
    let l2 = l1 + count q0 q1 - (if q1 > q0 && t.[q1 - 1] = '\n' then 1 else 0) in
    Buffer.add_string out (if l2 <> l1 then Printf.sprintf "%d,%d; " l1 l2 else Printf.sprintf "%d; " l1)
  end;
  Buffer.add_string out (if q1 <> q0 then Printf.sprintf "#%d,#%d\n" q0 q1 else Printf.sprintf "#%d\n" q0)

(* the file's line in sam's menu: ' when modified *)
let menu name = Printf.sprintf "%c-. %s\n" (if !modified then '\'' else ' ') name

let read_file name = try Some (In_channel.with_open_bin name In_channel.input_all) with Sys_error _ -> None

let rec exec (c : cmd) : unit =
  let a = match c.addr, c.op with None, File (Write, _) -> (0, len ()) | None, _ -> !dot | Some ad, _ -> address ad !dot in
  let q0, q1 = a in
  match c.op with
  | Text (w, s) ->
      (* the range the text replaces *)
      let p0, p1 = match w with After -> q1, q1 | Before -> q0, q0 | Instead -> q0, q1 in
      change p0 p1 s;
      dot := (p0, p0 + String.length s)
  | Delete -> change q0 q1 ""; dot := (q0, q0)
  | Subst (n, pat, rep, g) ->
      let re = compile pat in
      let n = ref n and p = ref q0 and op = ref (-1) and did = ref false and delta = ref 0 in
      (try
         while !p <= q1 do
           match search re !text !p q1 with
           | None -> raise Exit
           | Some m ->
               let s, e = m.(0), m.(1) in
               if s = e && s = !op then incr p
               else begin
                 p := if s = e then e + 1 else e;
                 op := e;
                 decr n;
                 if !n <= 0 then begin
                   let b = Buffer.create 16 in
                   let i = ref 0 in
                   while !i < String.length rep do
                     (match rep.[!i] with
                      | '\\' when !i + 1 < String.length rep ->
                          incr i;
                          (match rep.[!i] with
                           | '1' .. '9' as d ->
                               let g = Char.code d - 48 in
                               if m.(2 * g) >= 0 && m.((2 * g) + 1) >= 0 then Buffer.add_string b (String.sub !text m.(2 * g) (m.((2 * g) + 1) - m.(2 * g)))
                           | c -> Buffer.add_char b c)
                      | '&' -> Buffer.add_string b (String.sub !text s (e - s))
                      | c -> Buffer.add_char b c);
                     incr i
                   done;
                   change s e (Buffer.contents b);
                   delta := !delta + Buffer.length b - (e - s);
                   did := true;
                   if not g then raise Exit
                 end
               end
         done
       with Exit -> ());
      if not !did then raise (Error "substitution");
      dot := (q0, q1 + !delta)
  | Print -> Buffer.add_string out (String.sub !text q0 (q1 - q0)); dot := a
  | Eq chars -> print_posn a chars
  | Move (m, dest) ->
      let d = chain_address dest !dot in
      let s = String.sub !text q0 (q1 - q0) in
      let p = snd d in
      if m then begin
        (* claude: as sam's move: after the range, or before it (its
         * start included: 2m1 is allowed) *)
        if q1 <= p then (change q0 q1 ""; change p p s)
        else if q0 >= p then (change p p s; change q0 q1 "")
        else raise (Error "addresses overlap");
        dot := (shift p - (if p >= q1 then q1 - q0 else 0), shift p - (if p >= q1 then q1 - q0 else 0) + String.length s)
      end
      else (change p p s; dot := (p, p + String.length s))
  | Loop (If (g, pat), sub) ->
      let found = search (compile pat) !text q0 q1 <> None in
      if found = g then (dot := a; exec sub)
  | Loop (Lines, sub) ->
      let p = ref q0 in
      while !p < q1 do
        let e = match String.index_from_opt !text !p '\n' with Some e when e < q1 -> e + 1 | _ -> q1 in
        dot := (!p, e);
        exec sub;
        p := e
      done
  | Loop ((Matches pat | Between pat) as k, sub) ->
      (* looper(): x on each match, y on the text between *)
      let x = match k with Matches _ -> true | _ -> false in
      let re = compile pat in
      let p = ref q0 and op = ref (if x then -1 else q0) in
      (try
         while !p <= q1 do
           match search re !text !p q1 with
           | None ->
               if x || !op > q1 then raise Exit;
               dot := (!op, q1);
               p := q1 + 1;
               exec sub
           | Some m ->
               let s, e = m.(0), m.(1) in
               if s = e && s = !op then incr p
               else begin
                 p := if s = e then e + 1 else e;
                 dot := if x then (s, e) else (!op, s);
                 op := e;
                 exec sub
               end
         done
       with Exit -> ())
  | Block cmds -> List.iter (fun c -> dot := a; exec c) cmds
  | File (Read, name) -> (
      match read_file name with
      | Some s -> change q0 q1 s; dot := (q0, q0 + String.length s); Buffer.add_string out (Printf.sprintf "#%d\n" (String.length s))
      | None -> raise (Error ("can't open " ^ name)))
  | File (Write, name) ->
      let name = if name = "" then !file else name in
      if name = "" then raise (Error "no file name");
      Out_channel.with_open_bin name (fun oc -> output_string oc (String.sub !text q0 (q1 - q0)));
      if name = !file && q0 = 0 && q1 = len () then modified := false;
      if !file = "" then file := name;
      Buffer.add_string out (name ^ ": ");
      if q1 > q0 && !text.[q1 - 1] <> '\n' then (flush (); prerr_endline "?warning: last char not newline");
      Buffer.add_string out (Printf.sprintf "#%d\n" (q1 - q0))
  | File (Edit, name) ->
      let name = if name = "" then !file else name in
      (match read_file name with
       | Some s -> text := s; file := name; dot := (0, 0); modified := false
       | None -> raise (Error ("can't open " ^ name)));
      Buffer.add_string out (menu name)
  | File (Name, name) -> if name <> "" then file := name; Buffer.add_string out (menu !file)
  | Quit ->
      if !modified && not !warned then (warned := true; raise (Error "changed files"));
      flush ();
      exit 0
  | Newline -> (
      (* the next line, or the line dot is in if it is not one *)
      match c.addr with
      | Some _ -> Buffer.add_string out (String.sub !text q0 (q1 - q0)); dot := a
      | None ->
          let b0, _ = lineaddr 0 !dot (-1) and _, b1 = lineaddr 0 !dot 1 in
          let r = if (b0, b1) = !dot then lineaddr 1 !dot 1 else (b0, b1) in
          Buffer.add_string out (String.sub !text (fst r) (snd r - fst r));
          dot := r)

let () =
  (match Sys.argv with
   | [| _; name |] ->
       file := name;
       text := Option.value (read_file name) ~default:"";
       Buffer.add_string out (menu name)
   | _ -> ());
  input := In_channel.input_all stdin;
  let rec loop () =
    match parse () with
    | None -> ()
    | Some c ->
        (* an error while it runs: its changes are dropped *)
        (try exec c; apply ()
         with Error m ->
           changes := [];
           hi := 0;
           flush ();
           prerr_endline ("?" ^ m));
        flush ();
        loop ()
    | exception Error m ->
        (* an error while it is read: the rest of the line thrown away *)
        flush ();
        prerr_endline ("?" ^ m);
        while peekc () <> '\n' && peekc () <> '\000' do incr ip done;
        if peekc () = '\n' then incr ip;
        loop ()
  in
  loop ();
  if !modified && not !warned then (flush (); prerr_endline "?changed files");
  flush ()
