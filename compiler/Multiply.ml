(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Multiply.mli *)

(* A multiplication by a constant as shifts, adds and subtracts, at most
 * three of them, found by a search (5c's mul.c). A program is pairs:
 * a letter a-z, a shift by its rank, then which registers (0 or 1, as
 * bits: result, operand); + or -, then result, left, right. The search
 * is not exhaustive: the numbers it misses are in a table of hints. *)

let hints = [
  683, "b++d+e+"; 687, "b+e++e-"; 691, "b++d+e+"; 731, "b++d+e+"; 811, "b++d+i+"; 821, "b++e+e+";
  843, "b+d++e+"; 851, "b+f-+e-"; 853, "b++e+e+"; 877, "c++++g-"; 933, "b+c++g-"; 981, "c-+e-d+";
  1375, "b+c+b+h-"; 1675, "d+b++h+"; 2425, "c++f-e+"; 2675, "c+d++f-"; 2750, "b+d-b+h-"; 2775, "c-+g-e-";
  3125, "b++e+g+"; 3275, "b+c+g+e+"; 3350, "c++++i+"; 3475, "c-+e-f-"; 3525, "c-+d+g-"; 3625, "c-+e-j+";
  3675, "b+d+d+e+"; 3725, "b+d-+h+"; 3925, "b+d+f-d-"; 4275, "b+g++e+"; 4325, "b+h-+d+"; 4425, "b+b+g-j-";
  4525, "b+d-d+f+"; 4675, "c++d-g+"; 4775, "b+d+b+g-"; 4825, "c+c-+i-"; 4850, "c++++i-"; 4925, "b++e-g-";
  4975, "c+f++e-"; 5500, "b+g-c+d+"; 6700, "d+b++i+"; 9700, "d++++j-"; 11000, "b+f-c-h-"; 11750, "b+d+g+j-";
  12500, "b+c+e-k+"; 13250, "b+d+e-f+"; 13750, "b+h-c-d+"; 14250, "b+g-c+e-"; 14500, "c+f+j-d-";
  14750, "d-g--f+"; 16750, "b+e-d-n+"; 17750, "c+h-b+e+"; 18250, "d+b+h-d+"; 18750, "b+g-++f+";
  19250, "b+e+b+h+"; 19750, "b++h--f-"; 20250, "b+e-l-c+"; 20750, "c++bi+e-"; 21250, "b+i+l+c+";
  22000, "b+e+d-g-"; 22250, "b+d-h+k-"; 22750, "b+d-e-g+"; 23250, "b+c+h+e-"; 23500, "b+g-c-g-";
  23750, "b+g-b+h-"; 24250, "c++g+m-"; 24750, "b+e+e+j-"; 25000, "b++dh+g+"; 25250, "b+e+d-g-";
  25750, "b+e+b+j+"; 26250, "b+h+c+e+"; 26500, "b+h+c+g+"; 26750, "b+d+e+g-"; 27250, "b+e+e+f+";
  27500, "c-i-c-d+"; 27750, "b+bd++j+"; 28250, "d-d-++i-"; 28500, "c+c-h-e-"; 29000, "b+g-d-f+";
  29500, "c+h+++e-"; 29750, "b+g+f-c+"; 30250, "b+f-g-c+"; 33500, "c-f-d-n+"; 33750, "b+d-b+j-";
  34250, "c+e+++i+"; 35250, "e+b+d+k+"; 35500, "c+e+d-g-"; 35750, "c+i-++e+"; 36250, "b+bh-d+e+";
  36500, "c+c-h-e-"; 36750, "d+e--i+"; 37250, "b+g+g+b+"; 37500, "b+h-b+f+"; 37750, "c+be++j-";
  38500, "b+e+b+i+"; 38750, "d+i-b+d+"; 39250, "b+g-l-+d+"; 39500, "b+g-c+g-"; 39750, "b+bh-c+f-";
  40250, "b+bf+d+g-"; 40500, "b+g-c+g+"; 40750, "c+b+i-e+"; 41250, "d++bf+h+"; 41500, "b+j+c+d-";
  41750, "c+f+b+h-"; 42500, "c+h++g+"; 42750, "b+g+d-f-"; 43250, "b+l-e+d-"; 43750, "c+bd+h+f-";
  44000, "b+f+g-d-"; 44250, "b+d-g--f+"; 44500, "c+e+c+h+"; 44750, "b+e+d-h-"; 45250, "b++g+j-g+";
  45500, "c+d+e-g+"; 45750, "b+d-h-e-"; 46250, "c+bd++j+"; 46500, "b+d-c-j-"; 46750, "e-e-b+g-";
  47000, "b+c+d-j-"; 47250, "b+e+e-g-"; 47500, "b+g-c-h-"; 47750, "b+f-c+h-"; 48250, "d--h+n-";
  48500, "b+c-g+m-"; 48750, "b+e+e-g+"; 49500, "c-f+e+j-"; 49750, "c+c+g++f-"; 50000, "b+e+e+k+";
  50250, "b++i++g+"; 50500, "c+g+f-i+"; 50750, "b+e+d+k-"; 51500, "b+i+c-f+"; 51750, "b+bd+g-e-";
  52250, "b+d+g-j+"; 52500, "c+c+f+g+"; 52750, "b+c+e+i+"; 53000, "b+i+c+g+"; 53500, "c+g+g-n+";
  53750, "b+j+d-c+"; 54250, "b+d-g-j-"; 54500, "c-f+e+f+"; 54750, "b+f-+c+g+"; 55000, "b+g-d-g-";
  55250, "b+e+e+g+"; 55500, "b+cd++j+"; 55750, "b+bh-d-f-"; 56250, "c+d-b+j-"; 56500, "c+d+c+i+";
  56750, "b+e+d++h-"; 57000, "b+d+g-f+"; 57250, "b+f-m+d-"; 57750, "b+i+c+e-"; 58000, "b+e+d+h+";
  58250, "c+b+g+g+"; 58750, "d-e-j--e+"; 59000, "d-i-+e+"; 59250, "e--h-m+"; 59500, "c+c-h+f-";
  59750, "b+bh-e+i-"; 60250, "b+bh-e-e-"; 60500, "c+c-g-g-"; 60750, "b+e-l-e-"; 61250, "b+g-g-c+";
  61750, "b+g-c+g+"; 62250, "f--+c-i-"; 62750, "e+f--+g+"; 64750, "b+f+d+p-"
]

exception Found

(* the program of v in r0, the other register r1, from a hint's ops
 * (docode): each op tries its register choices in order *)
let rec docode mulval (hp : string) i (code : Buffer.t) r0 r1 =
  let len = Buffer.length code in
  let try_ digit r0 r1 = Buffer.add_char code digit; if docode mulval hp (i + 1) code r0 r1 then true else (Buffer.truncate code (len + 1); false) in
  let op c = Buffer.truncate code len; Buffer.add_char code c in
  if i >= String.length hp then r0 = mulval
  else
    match hp.[i] with
    | '+' ->
        op '+';
        try_ '1' (r0 + r1) r1 || (op '+'; try_ '5' r0 (r0 + r1)) || (Buffer.truncate code len; false)
    | '-' ->
        op '-';
        try_ '1' (r0 - r1) r1 || (op '-'; try_ '2' (r1 - r0) r1) || (op '-'; try_ '5' r0 (r0 - r1))
        || (op '-'; try_ '6' r0 (r1 - r0)) || (Buffer.truncate code len; false)
    | c ->
        let s = Char.code c - 97 in
        if s < 1 || s >= 30 then false
        else begin
          op c;
          try_ '0' (r0 lsl s) r1 || (op c; try_ '1' (r1 lsl s) r1) || (op c; try_ '2' r0 (r0 lsl s))
          || (op c; try_ '3' r0 (r1 lsl s)) || (Buffer.truncate code len; false)
        end

(* the search for the hint of mulval, in len ops (gen1, gen2, gen3):
 * the ops are prepended as found, from the last *)
let search mulval len =
  let shmax = let rec go s = if s >= 30 || 1 lsl s >= mulval then s else go (s + 1) in go 1 in
  (* claude: shmax ends at 30 when no shift reaches mulval, valmax at 2^29, as gen1's loop *)
  let valmax = 1 lsl (min shmax 29) in
  let ur1 = 4 and ur0 = 8 and sr1 = 1 and sr0 = 2 in
  let hint = ref "" in
  let out c = hint := String.make 1 c ^ !hint; true in
  let rec gen3 len r0 r1 flag =
    if r0 <= 0 || r0 >= r1 || r1 > valmax then false
    else begin
      let len = len - 1 in
      if len = 0 then begin
        let f1 = flag land (ur0 lor ur1) in
        let rec shifts i = i <= shmax && (let x = r1 lsl i in if x >= mulval then x = mulval && out (Char.chr (i + 97)) else shifts (i + 1)) in
        (f1 = ur1 && shifts 1) || (mulval = r1 + r0 && out '+') || (mulval = r1 - r0 && out '-')
      end
      else begin
        let shift_loop from pick =
          let rec go i = i <= shmax && (let x = from lsl i in x <= valmax && ((pick x && out (Char.chr (i + 97))) || go (i + 1))) in
          go 1
        in
        (flag land ur1 = 0 && shift_loop r0 (fun x -> gen3 len r0 x (ur1 lor sr1)))
        || (flag land ur0 = 0 && shift_loop r1 (fun x -> gen3 len r1 x (ur1 lor sr1)))
        || (flag land sr1 = 0 && shift_loop r1 (fun x -> gen3 len r0 x (ur1 lor sr1 lor (flag land ur0))))
        || (flag land sr0 = 0
            && (let f1 = ur0 lor sr0 lor (flag land (sr1 lor ur1)) in
                let f2 = ur1 lor sr1 lor (if flag land ur1 <> 0 then ur0 else 0) lor (if flag land sr1 <> 0 then sr0 else 0) in
                shift_loop r0 (fun x -> if x > r1 then gen3 len r1 x f2 else gen3 len x r1 f1)))
        || (let x = r1 + r0 in (gen3 len r0 x ur1 && out '+') || (gen3 len r1 x ur1 && out '+'))
        || (let x = r1 - r0 in
            (gen3 len x r1 ur0 && out '-')
            || (if x > r0 then gen3 len r0 x ur1 && out '-' else gen3 len x r0 ur0 && out '-'))
      end
    end
  in
  let gen2 len r1 =
    if len <= 0 then r1 = mulval
    else begin
      let len = len - 1 in
      if len = 0 then (mulval = r1 + 1 && out '+') || (mulval = r1 - 1 && out '-')
      else
        (gen3 len r1 (r1 + 1) ur1 && out '+') || (gen3 len (r1 - 1) r1 ur0 && out '-')
        || (gen3 len 1 (r1 + 1) ur1 && out '+') || (gen3 len 1 (r1 - 1) ur1 && out '-')
    end
  in
  let gen1 len =
    mulval = 1
    || (let len = len - 1 in
        let rec go i = i <= shmax && ((gen2 len (1 lsl i) && out (Char.chr (i + 97))) || go (i + 1)) in
        go 1)
  in
  if gen1 len then Some !hint else None

let maxmulops = 3

(* the program for v, or None: then a MUL *)
let rec mulcon0 v =
  let v = abs v in
  let code hint = let b = Buffer.create 20 in if docode v hint 0 b 1 0 then Some (Buffer.contents b) else None in
  if v = 0 then None
  else
    match List.assoc_opt v hints with
    | Some hint -> code hint
    | None ->
        let rec tries g =
          if g > maxmulops || (g >= maxmulops && v >= 65535) then None
          else match search v g with Some hint -> code hint | None -> tries (g + 1)
        in
        match tries 1 with
        | Some c -> Some c
        | None ->
            (* an odd factor's program, then a shift *)
            let rec twos v g = if v land 1 = 0 then twos (v lsr 1) (g + 1) else v, g in
            let odd, g = twos v 0 in
            if g = 0 then None
            else Option.map (fun c -> c ^ String.make 1 (Char.chr (g + 97)) ^ "0") (mulcon0 odd)
