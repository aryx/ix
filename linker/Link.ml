(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Link.mli *)

type kind = Undefined | Text | Data | Bss

type sym = {
  name : string;
  version : int;
  mutable kind : kind;
  mutable value : int;
  mutable size : int;
  created : int;
}

type prog = {
  mutable op : string;
  mutable suffixes : string list;
  mutable args : Asm.operand list;
  mutable pc : int;
  mutable target : prog option;
  version : int;
  where : string * int;
  mutable frame : int;
  mutable leaf : bool;
  mutable rule : int;
}

type data = { dsym : sym; off : int; width : int; value : Asm.operand; dversion : int }

type t = {
  arch : Asm.arch;
  syms : (string * int, sym) Hashtbl.t;
  mutable ncreated : int;
  mutable progs : prog list;
  mutable datas : data list;
  mutable text_start : int;
  mutable data_start : int;
  mutable text_size : int;
  mutable data_size : int;
  mutable bss_size : int;
}

exception Error of string

let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt
let rnd v r = (v + r - 1) / r * r

let create arch ~text_start =
  { arch; syms = Hashtbl.create 1024; ncreated = 0; progs = []; datas = [];
    text_start; data_start = 0; text_size = 0; data_size = 0; bss_size = 0 }

let lookup t name version =
  match Hashtbl.find_opt t.syms (name, version) with
  | Some s -> s
  | None ->
      let s = { name; version; kind = Undefined; value = 0; size = 0; created = t.ncreated } in
      t.ncreated <- t.ncreated + 1;
      Hashtbl.replace t.syms (name, version) s;
      s

let sym_of t version (n : Asm.name) = lookup t n.sym (if n.static then version else 0)

(*****************************************************************************)
(* Objects and libraries *)
(*****************************************************************************)

(* one object into the program (5l's ldobj): its instructions, its
 * TEXTs, GLOBLs and DATAs; each object has its own version, for its
 * name<>s *)
let add_object t version (o : Asm.obj) =
  if o.arch <> t.arch then error "%s: an object for another machine" o.file;
  let items = o.items in
  (* the prog of each item that has a pc; the targets point at items *)
  let progs = Array.map (fun (it, line) ->
    let mk op suffixes args = Some { op; suffixes; args; pc = 0; target = None; version; where = (o.file, line); frame = 0; leaf = false; rule = -1 } in
    match (it : Asm.item) with
    | Ins i -> mk i.op i.suffixes i.args
    | Text (n, flag, frame) ->
        let s = sym_of t version n in
        if s.kind = Text then error "%s:%d: %s defined twice" o.file line n.sym;
        s.kind <- Text;
        (match mk "TEXT" [] [ Asm.Mem { base = SB; name = Some n; off = 0L; index = None }; Asm.Imm (Int64.of_int flag) ] with
         | Some p -> p.frame <- rnd (Int64.to_int frame) 4; Some p
         | None -> None)
    | Globl (n, _, size) ->
        let s = sym_of t version n in
        if s.kind = Undefined then s.kind <- Bss;
        s.size <- max s.size (Int64.to_int size);
        None
    | Data (n, off, width, value) ->
        let s = sym_of t version n in
        t.datas <- { dsym = s; off = Int64.to_int off; width; value; dversion = version } :: t.datas;
        None) items in
  (* the symbols named, in the order of the object (as 5l meets them) *)
  Array.iter (fun (it, _) ->
    match (it : Asm.item) with
    | Ins i ->
        (* n(SB) only: n+4(FP) and n-8(SP) name a parameter and a local *)
        List.iter (function Asm.Mem { base = SB; name = Some n; _ } | Addr { base = SB; name = Some n; _ } -> ignore (sym_of t version n) | _ -> ()) i.args
    | Data (_, _, _, Addr { name = Some n; _ }) -> ignore (sym_of t version n)
    | _ -> ()) items;
  Array.iteri (fun i p ->
    match p with
    | Some p -> p.args <- List.map (function Asm.Target j -> (match progs.(j) with Some q -> p.target <- Some q | None -> ()); Asm.Target j | a -> a) p.args
    | None -> ignore i) progs;
  t.progs <- t.progs @ List.filter_map Fun.id (Array.to_list progs)

type library = (Asm.obj * string list) list   (* each object, and the names it defines *)

let lib_version = 1

(* the names an object defines, for the library's index: its TEXTs,
 * its GLOBLs and DATAs (ar's objsym, 'T' and 'D') *)
let defined_names (o : Asm.obj) =
  Array.to_list o.items |> List.filter_map (fun (it, _) ->
    match (it : Asm.item) with
    | Text (n, _, _) when not n.static -> Some (`T, n.sym)
    | Data (n, _, _, _) | Globl (n, _, _) when not n.static -> Some (`D, n.sym)
    | _ -> None)
  |> List.sort_uniq compare

(* as ar: a text name defined again by a later object is not indexed
 * for it *)
let make_library out files =
  let texts = Hashtbl.create 256 in
  let lib : library = List.map (fun f ->
    let o = Asm.load f in
    let names = List.filter_map (fun (k, n) ->
      if k = `T && Hashtbl.mem texts n then None else (if k = `T then Hashtbl.replace texts n (); Some n)) (defined_names o) in
    (o, List.sort_uniq compare names)) files in
  Out_channel.with_open_bin out (fun oc -> Marshal.to_channel oc (lib_version, lib) [])

let load t ?(needs = fun _ -> []) files =
  let version = ref 0 in
  let next () = incr version; !version in
  let libs = ref [] in
  List.iter (fun f ->
    if Filename.check_suffix f ".a" then
      In_channel.with_open_bin f (fun ic ->
        let v, (lib : library) = Marshal.from_channel ic in
        if v <> lib_version then error "%s: a library of another version" f;
        libs := !libs @ [ lib ])
    else add_object t (next ()) (Asm.load f)) files;
  (* 5l's loadlib: take the members that define an undefined name, until
   * no library adds one *)
  let loaded = Hashtbl.create 64 in
  let rec again () =
    let added = ref false in
    List.iteri (fun li lib ->
      (* ar's index lists the objects last first *)
      List.iteri (fun mi ((o : Asm.obj), names) ->
        if not (Hashtbl.mem loaded (li, mi))
           && List.exists (fun n -> match Hashtbl.find_opt t.syms (n, 0) with Some s -> s.kind = Undefined | None -> false) names
        then begin
          Hashtbl.replace loaded (li, mi) ();
          add_object t (next ()) o;
          added := true
        end) (List.rev lib)) !libs;
    if !added then again ()
  in
  again ();
  (* then the names the machine's rewriting will call (5l's needsdiv) *)
  List.iter (fun n -> ignore (lookup t n 0)) (needs t.progs);
  again ()

(*****************************************************************************)
(* Branches *)
(*****************************************************************************)

let is_branch op = op = "B" || op = "BL"

let resolve t =
  (* BL f(SB) and B f(SB): to f's TEXT *)
  let texts = Hashtbl.create 64 in
  List.iter (fun p ->
    if p.op = "TEXT" then match p.args with Asm.Mem { name = Some n; _ } :: _ -> Hashtbl.replace texts (sym_of t p.version n) p | _ -> ()) t.progs;
  List.iter (fun p ->
    match p.args with
    | [ Asm.Mem { base = SB; name = Some n; _ } ] when is_branch p.op -> (
        let s = sym_of t p.version n in
        match Hashtbl.find_opt texts s with
        | Some q -> p.target <- Some q
        | None -> let f, l = p.where in error "%s:%d: undefined: %s" f l n.sym)
    | _ -> ()) t.progs;
  (* a branch to an unconditional B goes where that B goes (brloop) *)
  let rec final q n =
    if n > 5000 then None
    else if q.op = "B" && q.suffixes = [] then (match q.target with Some r when r != q -> final r (n + 1) | _ -> if q.target = None then Some q else None)
    else Some q
  in
  List.iter (fun p -> match p.target with Some q -> p.target <- final q 0 | None -> ()) t.progs

(*****************************************************************************)
(* Data *)
(*****************************************************************************)

(* 5l's hash, over a C long: its buckets decide the data's order *)
let bucket name version =
  let h = ref (Int64.of_int version) in
  String.iter (fun c -> h := Int64.add (Int64.mul !h 3L) (Int64.of_int (Char.code c))) name;
  Int64.to_int (Int64.rem (Int64.logand !h 0xffffffL) 10007L)

let layout_data t =
  List.iter (fun d -> if d.dsym.kind = Bss || d.dsym.kind = Undefined then d.dsym.kind <- Data) t.datas;
  let syms = Hashtbl.fold (fun _ s acc -> if s.kind = Data || s.kind = Bss then s :: acc else acc) t.syms [] in
  (* 5l walks its buckets in order, each newest first *)
  let syms = List.sort (fun a b -> compare (bucket a.name a.version, - a.created) (bucket b.name b.version, - b.created)) syms in
  let orig = ref 0 in
  let small = Hashtbl.create 64 in
  List.iter (fun s ->
    let v = rnd (if s.size = 0 then 1 else s.size) 4 in
    s.size <- v;
    if v <= 64 then (s.value <- !orig; orig := !orig + v; Hashtbl.replace small s ()))
    syms;
  List.iter (fun s -> if s.kind = Data && not (Hashtbl.mem small s) then (s.value <- !orig; orig := !orig + s.size)) syms;
  List.iter (fun s -> if Hashtbl.mem small s then s.kind <- Data) syms;
  t.data_size <- rnd !orig 8;
  orig := t.data_size;
  List.iter (fun s -> if s.kind = Bss then (s.value <- !orig; orig := !orig + s.size)) syms;
  t.bss_size <- rnd !orig 8 - t.data_size;
  let define name kind value =
    let s = lookup t name 0 in
    if s.kind = Undefined then (s.kind <- kind; s.value <- value)
  in
  define "bdata" Data 0;
  define "edata" Data t.data_size;
  define "end" Bss (t.data_size + t.bss_size);
  define "etext" Text 0;
  define "setR12" Data 4092

let put32 b off v =
  Bytes.set b off (Char.chr (v land 255));
  Bytes.set b (off + 1) (Char.chr ((v lsr 8) land 255));
  Bytes.set b (off + 2) (Char.chr ((v lsr 16) land 255));
  Bytes.set b (off + 3) (Char.chr ((v lsr 24) land 255))

let put64 b off v = put32 b off (v land 0xffffffff); put32 b (off + 4) ((v lsr 32) land 0xffffffff)

(* a double's bits as a single's, as 5l rounds them (5l's ieeedtof):
 * half up, not to even *)
let single_bits x =
  let d = Int64.bits_of_float x in
  let h = Int64.to_int (Int64.shift_right_logical d 32) and l = Int64.to_int d land 0xffffffff in
  if h = 0 then 0
  else begin
    let exp = ref (((h lsr 20) land 0x7ff) - 1022) in
    let v = ref (((h land 0xfffff) lsl 3) lor ((l lsr 29) land 7)) in
    if (l lsr 28) land 1 = 1 then begin
      incr v;
      if !v land 0x800000 <> 0 then (v := (!v land 0x7fffff) lsr 1; incr exp)
    end;
    if !exp <= -126 || !exp >= 130 then error "double fp to single fp overflow";
    !v lor (((!exp + 126) land 0xff) lsl 23) lor (h land 0x80000000)
  end

(* an address as data: a text symbol's is absolute, a data symbol's is
 * the data's start plus its offset *)
let address t version (m : Asm.mem) =
  match m.name with
  | Some n ->
      let s = sym_of t version n in
      (match s.kind with Text -> s.value | Data | Bss -> s.value + t.data_start | Undefined -> error "undefined: %s" n.sym)
      + Int64.to_int m.off
  | None -> Int64.to_int m.off

let data_bytes t =
  let b = Bytes.make t.data_size '\000' in
  List.iter (fun d ->
    let a = d.dsym.value + d.off in
    if d.dsym.kind = Data && a >= 0 && a + d.width <= t.data_size then
      match d.value with
      | Asm.Str s -> for i = 0 to d.width - 1 do Bytes.set b (a + i) (if i < String.length s then s.[i] else '\000') done
      | Imm n ->
          let v = Int64.to_int n in
          for i = 0 to d.width - 1 do Bytes.set b (a + i) (Char.chr ((v asr (8 * i)) land 255)) done
      | Addr m ->
          let v = address t d.dversion m in
          for i = 0 to d.width - 1 do Bytes.set b (a + i) (Char.chr ((v asr (8 * i)) land 255)) done
      | Fimm x ->
          let bits = if d.width = 4 then Int64.of_int (single_bits x) else Int64.bits_of_float x in
          for i = 0 to d.width - 1 do Bytes.set b (a + i) (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical bits (8 * i)) 255L))) done
      | _ -> error "DATA %s: a value of an unknown kind" d.dsym.name) t.datas;
  b

let entry t name =
  match Hashtbl.find_opt t.syms (name, 0) with
  | Some { kind = Text; value; _ } -> value
  | _ -> error "entry %s: not defined" name
