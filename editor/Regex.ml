(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Regex.mli *)

exception Error of string

(*****************************************************************************)
(* The tree, parsed *)
(*****************************************************************************)

type node =
  | Rune of int
  | Any
  | Class of bool * (int * int) list   (* negated, and its spans *)
  | Bol
  | Eol
  | Cat of node * node
  | Alt of node * node
  | Repeat of rep * node
  | Group of int * node

(* x*, x+, x?, in regcomp's order of priority *)
and rep = Star | Plus | Quest

let ngroups = 9   (* the whole match and \1-\8, as ed's MAXSUB *)

(* the character at [i] of [s], and its length in bytes; 0 at the end *)
let rune s i =
  if i >= String.length s then 0, 1
  else
    let d = String.get_utf_8_uchar s i in
    Uchar.to_int (Uchar.utf_decode_uchar d), Uchar.utf_decode_length d

(* regcomp.c's grammar, by recursive descent; | and concatenation
 * associate to the left, as its operator stack does, which matters
 * for the order of the threads:
 *   e0: e1 | e0 '|' e1    e1: e2 | e1 e2    e2: e3 | e2 REP    e3: atom | '(' e0 ')' *)
let parse (p : string) : node =
  let pos = ref 0 and groups = ref 0 in
  (* the next character, and whether a \ quoted it *)
  let next () =
    if !pos >= String.length p then None
    else
      let quoted = p.[!pos] = '\\' && !pos + 1 < String.length p in
      if quoted then incr pos;
      let c, n = rune p !pos in
      pos := !pos + n;
      Some (c, quoted)
  in
  let peek () = let save = !pos in let t = next () in pos := save; t in
  let is c = match peek () with Some (c', false) -> c' = Char.code c | _ -> false in
  (* [...] and [^...]; a negated class has a first span of \n, so it
   * never matches one, and a - after it makes a range from \n *)
  let cclass () =
    let neg = is '^' in
    if neg then ignore (next ());
    let rec spans acc =
      match next () with
      | None -> raise (Error "malformed '[]'")
      | Some (c, false) when c = Char.code ']' -> acc
      | Some (c, false) when c = Char.code '-' -> (
          match acc, next () with
          | [], _ | _, None -> raise (Error "malformed '[]'")
          | _, Some (c', false) when c' = Char.code ']' -> raise (Error "malformed '[]'")
          | (lo, _) :: rest, Some (hi, _) -> spans ((lo, hi) :: rest))
      | Some (c, _) -> spans ((c, c) :: acc)
    in
    let s = spans (if neg then [ (10, 10) ] else []) in
    if s = [] then raise (Error "malformed '[]'");
    Class (neg, s)
  in
  let rec e0 () =
    let rec more a = if is '|' then (ignore (next ()); more (Alt (a, e1 ()))) else a in
    more (e1 ())
  and e1 () =
    let rec more a =
      match peek () with
      | None -> a
      | Some (c, false) when c = Char.code '|' || c = Char.code ')' -> a
      | Some _ -> more (Cat (a, e2 ()))
    in
    more (e2 ())
  (* the repeats go through regcomp's operator stack, where * < + < ?
   * and an operator pops only those of its priority or higher: so
   * x+* is (x+)*, but x*+ is (x+)* too, the + applied first *)
  and e2 () =
    let a = e3 () in
    let prio = function Star -> 0 | Plus -> 1 | Quest -> 2 in
    let apply a r = Repeat (r, a) in
    let rec reps a stack =
      match List.find_opt (fun (c, _) -> is c) [ '*', Star; '+', Plus; '?', Quest ] with
      | Some (_, r) ->
          ignore (next ());
          let rec pop a = function
            | top :: rest when prio top >= prio r -> pop (apply a top) rest
            | stack -> a, stack
          in
          let a, stack = pop a stack in
          reps a (r :: stack)
      | None -> List.fold_left apply a stack
    in
    reps a []
  and e3 () =
    match next () with
    | None -> raise (Error "missing operand")
    | Some (c, true) -> Rune c
    | Some (c, false) when c > 127 -> Rune c
    | Some (c, false) -> (
        match Char.chr c with
        | '.' -> Any
        | '^' -> Bol
        | '$' -> Eol
        | '[' -> cclass ()
        | '(' ->
            incr groups;
            let g = !groups in
            let e = e0 () in
            if not (is ')') then raise (Error "unmatched left paren");
            ignore (next ());
            Group (g, e)
        | '*' | '+' | '?' | '|' | ')' -> raise (Error "missing operand")
        | _ -> Rune c)
  in
  let root = e0 () in
  if !pos < String.length p then raise (Error "unmatched right paren");
  root

(*****************************************************************************)
(* The program, as regcomp.c makes it *)
(*****************************************************************************)

type kind =
  | IRune of int
  | IAny
  | IClass of bool * (int * int) list
  | IBol
  | IEol
  | ILbra of int
  | IRbra of int
  | IOr of int   (* the right, queued; next, the left, followed at once *)
  | IEnd

type inst = { kind : kind; next : int }

type t = { prog : inst array; start : int }

(* old: each piece a (first, last) pair, last's next set by what came
 * after (-1 until then), a right field only an OR used, and NOPs
 * removed by a pass: the matcher had an INop case that could not run *)

(* evaluntil()'s cases, each piece emitted knowing what follows it (k):
 * its first instruction. The skip of *, + and ? and the right side of
 * | are the OR's next: followed first. A loop's OR is reserved, then
 * filled once its body, which comes back to it, is emitted *)
let compile (p : string) : t =
  let root = parse p in
  let code = Hashtbl.create 16 in
  let reserve () = let id = Hashtbl.length code in Hashtbl.replace code id { kind = IEnd; next = -1 }; id in
  let fill id kind next = Hashtbl.replace code id { kind; next } in
  let mk kind next = let id = reserve () in fill id kind next; id in
  let rec emit n k =
    match n with
    | Rune c -> mk (IRune c) k
    | Any -> mk IAny k
    | Class (neg, s) -> mk (IClass (neg, s)) k
    | Bol -> mk IBol k
    | Eol -> mk IEol k
    | Cat (a, b) -> emit a (emit b k)
    | Alt (a, b) -> let right = emit a k in let left = emit b k in mk (IOr right) left
    | Repeat (Quest, a) -> let right = emit a k in mk (IOr right) k
    | Repeat (((Star | Plus) as r), a) ->
        let o = reserve () in
        let f = emit a o in
        fill o (IOr f) k;
        if r = Star then o else f
    | Group (g, a) -> mk (ILbra g) (emit a (mk (IRbra g) k))
  in
  let start = emit root (mk IEnd (-1)) in
  { prog = Array.init (Hashtbl.length code) (Hashtbl.find code); start }

(*****************************************************************************)
(* Running it, as regexec.c does *)
(*****************************************************************************)

(* a thread: an instruction and its own captures (start, end) *)
type thread = { pc : int; mutable caps : int array }

exception Overflow

(* a list of threads, of rregexec's fixed size *)
type list_ = { mutable ts : thread array; mutable n : int; cap : int }

let exec1 (re : t) (s : string) (from : int) (cap : int) best =
  let len = String.length s in
  let fresh_list () = { ts = [||]; n = 0; cap } in
  let push l t =
    l.ts <- Array.append l.ts [| t |];
    l.n <- l.n + 1;
    (* claude: rregexec tests for its end exactly, and the start thread is
     * added unchecked, so C can go past it (and write out of bounds);
     * here, far enough past it stops too *)
    if l.n = l.cap - 2 || l.n > 4 * l.cap then raise Overflow
  in
  (* _renewthread: at most one thread per instruction from [from] on; an
   * earlier start replaces the one there. An OR looks only at the
   * threads not processed yet (it passes its own place), so a loop
   * that comes back to an instruction already run adds it again --
   * the "optimization" regaux.c's comment warns about *)
  let renew l ~from pc caps =
    let rec find i = if i >= l.n then None else if l.ts.(i).pc = pc then Some l.ts.(i) else find (i + 1) in
    match find from with
    | Some t -> if caps.(0) < t.caps.(0) then t.caps <- Array.copy caps
    | None -> push l { pc; caps = Array.copy caps }
  in
  let rec step pos (clist : list_) =
    let r, n = rune s pos in
    let nlist = fresh_list () in
    (* a thread for a match starting here, at every position (rregexec
     * adds it even after a match; an earlier start wins anyway) *)
    let fresh = Array.make (2 * ngroups) (-1) in
    fresh.(0) <- pos;
    (match Array.find_opt (fun t -> t.pc = re.start) (Array.sub clist.ts 0 clist.n) with
     | Some t -> if pos < t.caps.(0) then t.caps <- fresh
     | None -> clist.ts <- Array.append clist.ts [| { pc = re.start; caps = fresh } |]; clist.n <- clist.n + 1);
    let i = ref 0 in
    while !i < clist.n do
      let t = clist.ts.(!i) in
      let rec run pc =
        let inst = re.prog.(pc) in
        match inst.kind with
        | IRune c -> if r = c then renew nlist ~from:0 inst.next t.caps
        | IAny -> if r <> 10 then renew nlist ~from:0 inst.next t.caps
        | IClass (neg, spans) ->
            if List.exists (fun (lo, hi) -> lo <= r && r <= hi) spans <> neg then renew nlist ~from:0 inst.next t.caps
        | ILbra g -> t.caps.(2 * g) <- pos; run inst.next
        | IRbra g -> t.caps.((2 * g) + 1) <- pos; run inst.next
        | IBol -> if pos = 0 || s.[pos - 1] = '\n' then run inst.next
        | IEol -> if pos >= len || r = 10 then run inst.next
        | IOr right -> renew clist ~from:!i right t.caps; run inst.next
        | IEnd ->
            t.caps.(1) <- pos;
            (* _renewmatch: the leftmost, then the longest *)
            match !best with
            | Some b when not (t.caps.(0) < fst b.(0) || (t.caps.(0) = fst b.(0) && pos > snd b.(0))) -> ()
            | _ ->
                best := Some (Array.init ngroups (fun g ->
                  let a = t.caps.(2 * g) and b = t.caps.((2 * g) + 1) in
                  if a >= 0 && b >= 0 then (a, b) else (-1, -1)))
      in
      run t.pc;
      incr i
    done;
    if pos < len then step (pos + n) nlist
  in
  step from (fresh_list ())

(* rregexec: lists of 10 threads, then of 50; when even those overflow,
 * -1, which ed takes for a match: the best one found so far *)
let exec (re : t) (s : string) (from : int) : (int * int) array option =
  let best = ref None in
  try exec1 re s from 10 best; !best
  with Overflow -> (
    best := None;
    try exec1 re s from 50 best; !best
    with Overflow ->
      match !best with
      | Some b -> Some b
      | None -> Some (Array.init ngroups (fun g -> if g = 0 then (from, from) else (-1, -1))))
