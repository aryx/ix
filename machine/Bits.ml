(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Bits.mli *)

let native = Sys.int_size > 32

(* the 32-bit constants computed, not written: js_of_ocaml warns of the
 * literals it must truncate *)
let m32 = if native then (1 lsl 32) - 1 else -1
let top = 1 lsl 31

let field w lo n = (w lsr lo) land ((1 lsl n) - 1)
let bit w n = (w lsr n) land 1 = 1

let sign_extend bits v = let s = 1 lsl (bits - 1) in (v land ((1 lsl bits) - 1) lxor s) - s

(* all ones is -1 under js_of_ocaml: the same 32 bits *)
let mask32 w = if native then w land m32 else w

let ror32 w n =
  let n = n land 31 in
  if n = 0 then mask32 w else mask32 ((w lsr n) lor (w lsl (32 - n)))

let signed32 w = if native then (if w land top <> 0 then w lor lnot m32 else w land m32) else w

let unsigned32 w = if native then w land m32 else w

(* flipping bit 31 maps unsigned order onto signed order *)
let ule32 a b = if native then a land m32 <= b land m32 else a lxor top <= b lxor top
let ult32 a b = if native then a land m32 < b land m32 else a lxor top < b lxor top

let to_hex32 w =
  if native then Printf.sprintf "0x%x" (w land m32)
  else if w >= 0 then Printf.sprintf "0x%x" w
  else Printf.sprintf "0x%x%07x" ((w lsr 28) land 0xf) (w land 0xfffffff)

let of_int32 i = mask32 (Int32.to_int i)
let to_int32 w = Int32.of_int (signed32 w)

let add_carry a b cin =
  let r = mask32 (a + b + cin) in
  let c = if cin = 0 then ult32 r a else ule32 r a in
  let v = (a lxor r) land (b lxor r) land top <> 0 in
  r, c, v

let mul64 ~signed a b =
  let ext w = if signed then Int64.of_int (signed32 w) else Int64.logand (Int64.of_int (signed32 w)) 0xffffffffL in
  let p = Int64.mul (ext a) (ext b) in
  of_int32 (Int64.to_int32 p), of_int32 (Int64.to_int32 (Int64.shift_right_logical p 32))

let lsl32 w n = mask32 (w lsl n)
let lsr32 w n = if n = 0 then w else (unsigned32 w) lsr n
let asr32 w n = mask32 (signed32 w asr n)
