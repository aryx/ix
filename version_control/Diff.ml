(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Diff.mli *)

type whitespace = Exact | Collapse | Strip
type mode = Normal | Ed | Forward | Numbered | Context | All | Unified
type file = { name : string; lines : string array }
type change = { oldx : int; oldy : int; newx : int; newy : int }

let maxline = 4096

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\011' || c = '\012'

(*****************************************************************************)
(* Reading and hashing *)
(*****************************************************************************)

(* readline: through the newline, at most 4,095 bytes, the rest of a
 * longer line skipped *)
let split (s : string) =
  let n = String.length s in
  let rec go pos acc =
    if pos >= n then List.rev acc
    else
      let nl = match String.index_from_opt s pos '\n' with Some i -> i | None -> n - 1 in
      let len = nl - pos + 1 in
      let line = if len > maxline - 1 then String.sub s pos (maxline - 1) else String.sub s pos len in
      go (nl + 1) (line :: acc)
  in
  go 0 []

(* in 7-bit steps, summed in 16-bit halves, as a sign-extended short
 * pair: 0 for none *)
let hash ws line =
  let sum = ref 1 and shift = ref 0 in
  let add c = shift := !shift land 15; sum := !sum + (Char.code c lsl !shift); shift := !shift + 7 in
  (match ws with
   | Exact -> String.iter add line
   | Collapse ->
       let space = ref false in
       String.iter (fun c -> if is_space c then space := true else begin
         if !space then (shift := !shift + 7; space := false);
         add c end) line
   | Strip -> String.iter (fun c -> if not (is_space c) then add c) line);
  let low x = x land 0xffff and high x = x asr 16 in
  let s = low !sum + high !sum in
  let short x = let x = x land 0xffff in if x >= 0x8000 then x - 0x10000 else x in
  short (low s) + short (high s)

(* the binary heuristic: runes of the first 1,024 bytes, as long as a
 * whole rune fits *)
let binary s =
  let n = min 1024 (String.length s) in
  let rec go i =
    if i >= n - 4 then false
    else
      let d = String.get_utf_8_uchar s i in
      let r = if Uchar.utf_decode_is_valid d then Uchar.to_int (Uchar.utf_decode_uchar d) else 0xfffd in
      if r = 0 || (r > 0x7f && r <= 0xa0) then true else go (i + Uchar.utf_decode_length d)
  in
  go 0

let read ws name s =
  if binary s then None
  else
    (* the lines up to the first one hashing to 0 *)
    let rec take = function l :: rest when hash ws l <> 0 -> l :: take rest | _ -> [] in
    Some { name; lines = Array.of_list (take (split s)) }

(*****************************************************************************)
(* Stone's algorithm *)
(*****************************************************************************)

type t = { f0 : file; f1 : file; j : int array; len0 : int; len1 : int }

(* C's %s and strcmp: a string stops at a NUL (a line then loses its
 * newline when printed) *)
let cstring l = match String.index_opt l '\000' with Some i -> String.sub l 0 i | None -> l

let squish ws s =
  let b = Buffer.create (String.length s) in
  let space = ref false in
  String.iter (fun c -> if is_space c then space := true else begin
    if !space && ws = Collapse then Buffer.add_char b ' ';
    space := false;
    Buffer.add_char b c end) s;
  Buffer.contents b

let compute ws (f0 : file) (f1 : file) =
  let len0 = Array.length f0.lines and len1 = Array.length f1.lines in
  (* file.(i) for i in 1..len, and room for len+1, len+2 *)
  let values f len = Array.init (len + 3) (fun i -> if i >= 1 && i <= len then hash ws f.lines.(i - 1) else 0) in
  let v0 = values f0 len0 and v1 = values f1 len1 in
  let pref = ref 0 in
  while !pref < len0 && !pref < len1 && v0.(!pref + 1) = v1.(!pref + 1) do incr pref done;
  let suff = ref 0 in
  while !suff < len0 - !pref && !suff < len1 - !pref && v0.(len0 - !suff) = v1.(len1 - !suff) do incr suff done;
  let pref = !pref and suff = !suff in
  let n = len0 - pref - suff and m = len1 - pref - suff in
  (* the shortened files, serial numbers from 0; sorted by (value, serial) *)
  let sfile v len = Array.init (len + 2) (fun i -> (v.(pref + i), i)) in
  let a = sfile v0 n and b = sfile v1 m in
  let sort arr len = let s = Array.sub arr 1 len in Array.stable_sort compare s; Array.blit s 0 arr 1 len in
  sort a n;
  sort b m;
  let aval = Array.map fst a and aser = Array.map snd a in
  let bval = Array.map fst b and bser = Array.map snd b in
  (* equiv *)
  let i = ref 1 and jj = ref 1 in
  while !i <= n && !jj <= m do
    if aval.(!i) < bval.(!jj) then (aval.(!i) <- 0; incr i)
    else if aval.(!i) = bval.(!jj) then (aval.(!i) <- !jj; incr i)
    else incr jj
  done;
  while !i <= n do aval.(!i) <- 0; incr i done;
  bval.(m + 1) <- 0;
  let member = Array.make (m + 2) 0 in
  let jj = ref 0 in
  incr jj;
  while !jj <= m do
    member.(!jj) <- - bser.(!jj);
    while bval.(!jj + 1) = bval.(!jj) do incr jj; member.(!jj) <- bser.(!jj) done;
    incr jj
  done;
  member.(!jj) <- -1;
  (* unsort *)
  let cls = Array.make (n + 2) 0 in
  for i = 1 to n do cls.(aser.(i)) <- aval.(i) done;
  (* stone *)
  let cands = ref [||] and clen = ref 0 in
  let newcand x y pred =
    if !clen = Array.length !cands then cands := Array.append !cands (Array.make (max 16 !clen) (0, 0, 0));
    !cands.(!clen) <- (x, y, pred);
    incr clen;
    !clen - 1 in
  let cy c = let _, y, _ = !cands.(c) in y in
  let klist = Array.make (n + 2) 0 in
  let search k y =
    if cy klist.(k) < y then k + 1
    else
      let rec go i j =
        let l = (i + j) / 2 in
        if l > i then
          let t = cy klist.(l) in
          if t > y then go i l else if t < y then go l j else `Found l
        else `Next (l + 1) in
      match go 0 (k + 1) with `Found l -> l | `Next l -> l in
  klist.(0) <- newcand 0 0 0;
  let k = ref 0 in
  for i = 1 to n do
    let j = cls.(i) in
    if j <> 0 then begin
      let j = ref j in
      let y = ref (- member.(!j)) in
      let oldl = ref 0 and oldc = ref klist.(0) in
      let stop = ref false in
      while not !stop do
        (if !y <= cy !oldc then ()
         else begin
           let l = search !k !y in
           if l <> !oldl + 1 then oldc := klist.(l - 1);
           if l <= !k then begin
             if cy klist.(l) <= !y then ()
             else begin
               let tc = klist.(l) in
               klist.(l) <- newcand i !y !oldc;
               oldc := tc;
               oldl := l
             end
           end
           else begin
             klist.(l) <- newcand i !y !oldc;
             incr k;
             stop := true
           end
         end);
        if not !stop then begin
          incr j;
          y := member.(!j);
          if !y <= 0 then stop := true
        end
      done
    end
  done;
  (* unravel *)
  let jv = Array.make (len0 + 2) 0 in
  for i = 0 to len0 do
    jv.(i) <- (if i <= pref then i else if i > len0 - suff then i + len1 - len0 else 0)
  done;
  let rec chain c = let x, y, pred = !cands.(c) in if y <> 0 then (jv.(x + pref) <- y + pref; chain pred) in
  chain klist.(!k);
  (* check: not the last line of the first file, as in the C *)
  for f = 1 to len0 - 1 do
    if jv.(f) <> 0 then begin
      let a = f0.lines.(f - 1) and b = f1.lines.(jv.(f) - 1) in
      let a, b = if ws <> Exact then squish ws a, squish ws b else a, b in
      (* the lengths, then strcmp, which stops at a NUL *)
      if String.length a <> String.length b || cstring a <> cstring b then jv.(f) <- 0
    end
  done;
  { f0; f1; j = jv; len0; len1 }


(*****************************************************************************)
(* Output *)
(*****************************************************************************)

let fetch b (lines : string array) ~maxb a bb s =
  let a = if a <= 1 then 1 else a in
  let bb = min bb maxb in
  if a <= maxb then
    for i = a to bb do
      let l = lines.(i - 1) in
      if l = "" || l.[String.length l - 1] <> '\n' then (Buffer.add_string b (s ^ cstring l ^ "\n"); Buffer.add_string b "\\ No newline at end of file\n")
      else Buffer.add_string b (s ^ cstring l)
    done

let range b a bb sep =
  Buffer.add_string b (string_of_int (if a > bb then bb else a));
  if a < bb then Buffer.add_string b (sep ^ string_of_int bb)

(* the changes, forward (or last first for -e), as output() makes them *)
let changes t ~backward =
  let m = t.len0 in
  let j = Array.copy t.j in
  let j = if Array.length j < m + 2 then Array.append j (Array.make (m + 2 - Array.length j) 0) else j in
  j.(0) <- 0;
  j.(m + 1) <- t.len1 + 1;
  let out = ref [] in
  let add a bb c d = if not (a > bb && c > d) then out := { oldx = a; oldy = bb; newx = c; newy = d } :: !out in
  if not backward then begin
    let i0 = ref 1 in
    while !i0 <= m do
      while !i0 <= m && j.(!i0) = j.(!i0 - 1) + 1 do incr i0 done;
      let j0 = j.(!i0 - 1) + 1 in
      let i1 = ref (!i0 - 1) in
      while !i1 < m && j.(!i1 + 1) = 0 do incr i1 done;
      let j1 = j.(!i1 + 1) - 1 in
      j.(!i1) <- j1;
      add !i0 !i1 j0 j1;
      i0 := !i1 + 1
    done
  end
  else begin
    let i0 = ref m in
    while !i0 >= 1 do
      while !i0 >= 1 && j.(!i0) = j.(!i0 + 1) - 1 && j.(!i0) <> 0 do decr i0 done;
      let j0 = j.(!i0 + 1) - 1 in
      let i1 = ref (!i0 + 1) in
      while !i1 > 1 && j.(!i1 - 1) = 0 do decr i1 done;
      let j1 = j.(!i1 - 1) + 1 in
      j.(!i1) <- j1;
      add !i1 !i0 j1 j0;
      i0 := !i1 - 1
    done
  end;
  if m = 0 then add 1 0 1 t.len1;
  List.rev !out

let changes_backward t = changes t ~backward:true

(* the C's anychange: a change was output *)
let differ t = changes t ~backward:false <> []
let lines0 t = t.f0.lines
let lines1 t = t.f1.lines

let context_lines = 3

let output ?(header = false) mode t =
  let b = Buffer.create 1024 in
  let chs = changes t ~backward:(mode = Ed) in
  let fetch0 a bb s = fetch b t.f0.lines ~maxb:t.len0 a bb s in
  let fetch1 a bb s = fetch b t.f1.lines ~maxb:t.len1 a bb s in
  if header && chs <> [] then begin
    let flag = match mode with Normal -> "" | Ed -> "-e " | Forward -> "-f " | Numbered -> "-n " | Context -> "-c " | All -> "-a " | Unified -> "-u " in
    Printf.bprintf b "diff %s%s %s\n" flag t.f0.name t.f1.name
  end;
  (match mode with
   | Normal | Ed | Forward | Numbered ->
       List.iter (fun { oldx = a; oldy = bb; newx = c; newy = d } ->
         let verb = if a > bb then 'a' else if c > d then 'd' else 'c' in
         (match mode with
          | Ed -> range b a bb ","; Buffer.add_char b verb
          | Normal -> range b a bb ","; Buffer.add_char b verb; range b c d ","
          | Numbered ->
              Printf.bprintf b "%s:" t.f0.name; range b a bb ",";
              Printf.bprintf b " %c %s:" verb t.f1.name; range b c d ","
          | _ -> Buffer.add_char b verb; range b a bb " ");
         Buffer.add_char b '\n';
         if mode = Normal || mode = Numbered then begin
           fetch0 a bb "< ";
           if a <= bb && c <= d then Buffer.add_string b "---\n"
         end;
         fetch1 c d (if mode = Normal || mode = Numbered then "> " else "");
         if mode <> Normal && mode <> Numbered && c <= d then Buffer.add_string b ".\n") chs
   | Context | All | Unified ->
       let chs = Array.of_list chs in
       let nch = Array.length chs in
       (* changeset: the changes whose contexts overlap the next's *)
       let changeset i =
         let i = ref i in
         while !i < nch - 1 && chs.(!i).oldy + 1 + (2 * context_lines) > chs.(!i + 1).oldx do incr i done;
         (* the C reads changes[nchanges], past the end, as zeros: never
          * merged *)
         if !i < nch then !i + 1 else nch in
       let hdr = ref false in
       let i = ref 0 in
       while !i < nch do
         let j = if mode = All then nch else changeset !i in
         let a, bb, c, d =
           if mode = All then 1, t.len0, 1, t.len1
           else
             max 1 (chs.(!i).oldx - context_lines), min t.len0 (chs.(j - 1).oldy + context_lines),
             max 1 (chs.(!i).newx - context_lines), min t.len1 (chs.(j - 1).newy + context_lines) in
         if mode = Unified then begin
           if not !hdr then (Printf.bprintf b "--- %s\n+++ %s\n" t.f0.name t.f1.name; hdr := true);
           Printf.bprintf b "@@ -%d,%d +%d,%d @@\n" a (bb - a + 1) c (d - c + 1)
         end
         else begin
           Printf.bprintf b "%s:" t.f0.name; range b a bb ",";
           Printf.bprintf b " - %s:" t.f1.name; range b c d ",";
           Buffer.add_char b '\n'
         end;
         let u = mode = Unified in
         let at = ref a in
         while !i < j do
           let ch = chs.(!i) in
           fetch0 !at (ch.oldx - 1) (if u then " " else "  ");
           fetch0 ch.oldx ch.oldy (if u then "-" else "- ");
           fetch1 ch.newx ch.newy (if u then "+" else "+ ");
           at := ch.oldy + 1;
           incr i
         done;
         fetch0 !at bb (if u then " " else "  ")
       done);
  Buffer.contents b
