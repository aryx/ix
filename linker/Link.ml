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

type cond = Asm.cond = EQ | NE | HS | LO | MI | PL | VS | VC | HI | LS | GE | LT | GT | LE

let invert = Asm.invert and cond_bits = Asm.cond_bits
let cond_of_string = Asm.cond_of_string and string_of_cond = Asm.string_of_cond

type 'm op = Func | Nop | B | Bl | Bcond of cond | Bcase | Ins of 'm

let decode machine = function
  | "NOP" -> Some Nop
  | "B" -> Some B
  | "BL" -> Some Bl
  | "BCASE" -> Some Bcase
  | s when String.length s = 3 && s.[0] = 'B' && cond_of_string (String.sub s 1 2) <> None ->
      Option.map (fun c -> Bcond c) (cond_of_string (String.sub s 1 2))
  | s -> Option.map (fun m -> Ins m) (machine s)

let show_op show = function
  | Func -> "TEXT" | Nop -> "NOP" | B -> "B" | Bl -> "BL" | Bcond c -> "B" ^ string_of_cond c | Bcase -> "BCASE"
  | Ins m -> show m

type 'm prog = {
  mutable op : 'm op;
  mutable suffixes : string list;
  mutable args : Asm.operand list;
  mutable pc : int;
  mutable target : 'm prog option;
  version : int;
  where : string * int;
  mutable frame : int;
  mutable leaf : bool;
}

type data = { dsym : sym; off : int; width : int; value : Asm.operand; dversion : int }

type 'm t = {
  arch : Asm.arch;
  syms : (string * int, sym) Hashtbl.t;
  mutable ncreated : int;
  mutable progs : 'm prog list;
  mutable datas : data list;
  mutable text_start : int;
  mutable data_start : int;
  mutable text_size : int;
  mutable data_size : int;
  mutable bss_size : int;
  mutable data_round : int;
  mutable pie : bool;
}

exception Error of string

let show show_m (p : _ prog) = Asm.show_item (Ins { op = show_op show_m p.op; suffixes = p.suffixes; args = p.args })

let error fmt = Printf.ksprintf (fun s -> raise (Error s)) fmt

(* a shift's kind, as both machines encode it *)
let shift_bits : Asm.shift_kind -> int = function Lsl -> 0 | Lsr -> 1 | Asr -> 2 | Ror -> 3
(* v rounded up to a multiple of r, negatives too (5l's rnd) *)
let rnd v r = let v = v + r - 1 in let c = v mod r in v - (if c < 0 then c + r else c)

let create arch ~text_start =
  { arch; syms = Hashtbl.create 1024; ncreated = 0; progs = []; datas = [];
    text_start; data_start = 0; text_size = 0; data_size = 0; bss_size = 0; data_round = 4096; pie = false }

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
let add_object t ~decode:decode_machine version (o : Asm.obj) =
  if o.arch <> t.arch then error "%s: an object for another machine" o.file;
  let items = o.items in
  (* the prog of each item that has a pc; the targets point at items *)
  let progs = Array.map (fun (it, line) ->
    let mk op suffixes args = Some { op; suffixes; args; pc = 0; target = None; version; where = (o.file, line); frame = 0; leaf = false } in
    match (it : Asm.item) with
    | Ins i -> (
        match decode decode_machine i.op with
        | Some op -> mk op i.suffixes i.args
        | None -> error "%s:%d: unknown opcode %s" o.file line i.op)
    | Text (n, flag, frame) ->
        let s = sym_of t version n in
        if s.kind = Text then error "%s:%d: %s defined twice" o.file line n.sym;
        s.kind <- Text;
        (match mk Func [] [ Asm.Mem { base = SB; name = Some n; off = 0L; index = None }; Asm.Imm (Int64.of_int flag) ] with
         | Some p -> p.frame <- Int64.to_int frame; Some p
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
let make_library caps out files =
  let texts = Hashtbl.create 256 in
  let lib : library = List.map (fun f ->
    let o = Asm.load caps f in
    let names = List.filter_map (fun (k, n) ->
      if k = `T && Hashtbl.mem texts n then None else (if k = `T then Hashtbl.replace texts n (); Some n)) (defined_names o) in
    (o, List.sort_uniq compare names)) files in
  Files.write caps out (Marshal.to_string (lib_version, lib) [])

let load caps t ~decode ?(needs = fun _ -> []) files =
  let add_object = add_object ~decode in
  let version = ref 0 in
  let next () = incr version; !version in
  let libs = ref [] in
  List.iter (fun f ->
    if Filename.check_suffix f ".a" then begin
      let v, (lib : library) = Marshal.from_string (Files.read caps f) 0 in
      if v <> lib_version then error "%s: a library of another version" f;
      libs := !libs @ [ lib ]
    end
    else add_object t (next ()) (Asm.load caps f)) files;
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

let is_branch = function B | Bl -> true | Func | Nop | Bcond _ | Bcase | Ins _ -> false

let resolve t =
  (* BL f(SB) and B f(SB): to f's TEXT *)
  let texts = Hashtbl.create 64 in
  List.iter (fun p ->
    if p.op = Func then match p.args with Asm.Mem { name = Some n; _ } :: _ -> Hashtbl.replace texts (sym_of t p.version n) p | _ -> ()) t.progs;
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
    else if q.op = B && q.suffixes = [] then (match q.target with Some r when r != q -> final r (n + 1) | _ -> if q.target = None then Some q else None)
    else Some q
  in
  List.iter (fun p -> match p.target with Some q -> p.target <- final q 0 | None -> ()) t.progs

(*****************************************************************************)
(* Following the flow *)
(*****************************************************************************)

(* the code in the order its flow goes, from the first TEXT: a branch
 * to code already placed becomes a copy of it when it is short and
 * ends the flow, else a B to it; a conditional branch is inverted when
 * that makes its target the next instruction; and what the flow never
 * reaches (code after a RET) is dropped. 5l's and 7l's xfol (not in
 * xix): [ends] says what ends the flow (a B, a RET), [invert] inverts
 * a conditional branch. xfol which builds the
 * new order in the progs' own links: once placed, an instruction's
 * next is what was placed after it. Here the links and the marks are
 * tables, by an id in pc (unused yet) *)
(* the NOPs out (5c -O0 leaves them), what branched to one to the next
 * instruction (5l's and 7l's noops) *)
let drop_nops t =
  let real = ref None and nops = ref [] in
  List.iter (fun (p : _ prog) -> if p.op = Nop then nops := (p, !real) :: !nops else real := Some p) (List.rev t.progs);
  if !nops <> [] then begin
    List.iter (fun (p : _ prog) -> match p.target with Some q when q.op = Nop -> p.target <- List.assq q !nops | _ -> ()) t.progs;
    t.progs <- List.filter (fun (p : _ prog) -> p.op <> Nop) t.progs
  end

let follow t ~ends =
  let invert (p : _ prog) =
    match p.op with
    | Bcond c -> Bcond (invert c)
    | Func | Nop | B | Bl | Bcase | Ins _ -> let f, l = p.where in error "%s:%d: unknown relation" f l in
  let link = Hashtbl.create 4096 and marked = Hashtbl.create 4096 in
  let ids = ref 0 in
  let fresh (p : _ prog) = p.pc <- !ids; incr ids in
  let rec links = function
    | (p : _ prog) :: (q :: _ as rest) -> fresh p; Hashtbl.replace link p.pc q; links rest
    | [ p ] -> fresh p
    | [] -> ()
  in
  links t.progs;
  let next (p : _ prog) = Hashtbl.find_opt link p.pc in
  let is_marked (p : _ prog) = Hashtbl.mem marked p.pc in
  let mark (p : _ prog) = Hashtbl.replace marked p.pc () in
  (* a TEXT's target is the next TEXT (5l's ldobj) *)
  let texts = List.filter (fun (p : _ prog) -> p.op = Func) t.progs in
  List.iteri (fun i (p : _ prog) -> p.target <- List.nth_opt (List.tl texts) i) texts;
  let rec chain (p : _ prog option) i =
    if i >= 20 then None else match p with Some (q : _ prog) when q.op = B -> chain q.target (i + 1) | _ -> p
  in
  let out = ref [] in
  let last () = match !out with q :: _ -> Some q | [] -> None in
  let emit (p : _ prog) =
    (match !out with l :: _ -> Hashtbl.replace link l.pc p | [] -> ());
    out := p :: !out
  in
  let rec xfol (p : _ prog option) =
    match p with
    | None -> ()
    | Some ({ op = B; target = Some q; _ } as p) when not (is_marked q) -> mark p; xfol (Some q)
    | Some p ->
        let p = match p.op, p.target with B, Some q -> mark p; q | _ -> p in
        if is_marked p then begin
          (* up to 4 instructions from p, if they end the flow *)
          let rec find (q : _ prog) i =
            if i >= 4 || (match last () with Some l -> l == q | None -> false) then None
            (* claude: a NOP (5c -O0's) doesn't count *)
            else if q.op = Nop then (match next q with Some r -> find r i | None -> None)
            else if ends q then Some q
            else if (q.op = Bcond EQ || q.op = Bcond NE) && (match q.target with Some c -> not (is_marked c) | None -> false) then Some q
            else match next q with Some r -> find r (i + 1) | None -> None
          in
          match find p 0 with
          | Some q ->
              let rec copy (p : _ prog) =
                let r = { p with pc = p.pc } (* a copy *) in
                fresh r;
                mark r;
                Option.iter (Hashtbl.replace link r.pc) (next p);
                emit r;
                if p != q then copy (Option.get (next p))
                else if not (ends q) then begin
                  r.op <- invert q;
                  r.target <- next q;
                  Option.iter (Hashtbl.replace link r.pc) q.target;
                  match q.target with Some l when not (is_marked l) -> xfol (Some l) | _ -> ()
                end
              in
              copy p
          | None ->
              let b = { p with op = B; suffixes = []; args = [ Asm.Target 0 ]; target = Some p } in
              fresh b;
              Hashtbl.remove link b.pc;
              mark b;
              emit b
        end
        else begin
          mark p;
          emit p;
          if not (ends p) then
            match p.target, next p with
            | Some _, Some l when p.op <> Bl ->
                let q = chain (Some l) 0 in
                (match q with
                 | Some q when p.op <> Func && p.op <> Bcase && is_marked q ->
                     p.op <- invert p;
                     Hashtbl.replace link p.pc (Option.get p.target);
                     p.target <- Some q
                 | _ -> ());
                xfol (next p);
                let q = match chain p.target 0 with None -> Option.get p.target | Some q -> q in
                if is_marked q then p.target <- Some q else xfol (Some q)
            | _ -> xfol (next p)
        end
  in
  (match t.progs with p :: _ -> xfol (Some p) | [] -> ());
  List.iter (fun (p : _ prog) -> if p.op = Func then p.target <- None) texts;
  t.progs <- List.rev !out

(*****************************************************************************)
(* Data *)
(*****************************************************************************)

(* the linker's hash, whose buckets decide the data's order: 5l's
 * over a C long, masked; 7l's over an int32, complemented if negative *)
let bucket arch name version =
  match (arch : Asm.arch) with
  | Arm ->
      let h = ref (Int64.of_int version) in
      String.iter (fun c -> h := Int64.add (Int64.mul !h 3L) (Int64.of_int (Char.code c))) name;
      Int64.to_int (Int64.rem (Int64.logand !h 0xffffffL) 10007L)
  | Arm64 ->
      let h = ref (Int32.of_int version) in
      String.iter (fun c -> h := Int32.add (Int32.mul !h 3l) (Int32.of_int (Char.code c))) name;
      let h = if Int32.compare !h 0l < 0 then Int32.lognot !h else !h in
      Int32.to_int (Int32.rem h 10007l)

(* 5l's and 7l's dodata: small symbols (<= 64 bytes, bss included)
 * first, then the data, then the bss; 7l aligns what is 8 bytes or
 * more to 8, 16 or more to 16 *)
let layout_data t =
  List.iter (fun d -> if d.dsym.kind = Bss || d.dsym.kind = Undefined then d.dsym.kind <- Data) t.datas;
  let syms = Hashtbl.fold (fun _ s acc -> if s.kind = Data || s.kind = Bss then s :: acc else acc) t.syms [] in
  (* in bucket order, each newest first *)
  let syms = List.sort (fun a b -> compare (bucket t.arch a.name a.version, - a.created) (bucket t.arch b.name b.version, - b.created)) syms in
  let orig = ref 0 in
  let place s =
    if t.arch = Arm64 then orig := (if s.size >= 16 then rnd !orig 16 else if s.size >= 8 then rnd !orig 8 else !orig);
    s.value <- !orig;
    orig := !orig + s.size
  in
  let small = Hashtbl.create 64 in
  List.iter (fun s ->
    s.size <- rnd (if s.size = 0 then 1 else s.size) 4;
    if s.size <= 64 then (place s; Hashtbl.replace small s ()))
    syms;
  List.iter (fun s -> if s.kind = Data && not (Hashtbl.mem small s) then place s) syms;
  List.iter (fun s -> if Hashtbl.mem small s then s.kind <- Data) syms;
  t.data_size <- rnd !orig 8;
  orig := t.data_size;
  List.iter (fun s -> if s.kind = Bss then place s) syms;
  t.bss_size <- rnd !orig 8 - t.data_size;
  let define name kind value =
    let s = lookup t name 0 in
    if s.kind = Undefined then (s.kind <- kind; s.value <- value)
  in
  (* R12 is setR12 on arm (data + 4092), R28 setSB on arm64 (data + 0) *)
  (match t.arch with Arm -> define "setR12" Data 4092 | Arm64 -> define "setSB" Data 0);
  define "bdata" Data 0;
  define "edata" Data t.data_size;
  define "end" Bss (t.data_size + t.bss_size);
  define "etext" Text 0

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

(* a float constant as data, in a symbol named by its bits, for the
 * machines that can't have it immediate (5l's and 7l's ldobj) *)
let float_constant t x ~single =
  let bits = Int64.bits_of_float x in
  let width, name =
    if single then 4, Printf.sprintf "$%x" (single_bits x)
    else 8, Printf.sprintf "$%Lx.%Lx" (Int64.logand bits 0xffffffffL) (Int64.shift_right_logical bits 32) in
  let s = lookup t name 0 in
  if s.kind = Undefined then begin
    s.kind <- Bss;
    s.size <- width;
    t.datas <- { dsym = s; off = 0; width; value = Asm.Fimm x; dversion = 0 } :: t.datas
  end;
  Asm.Mem { base = SB; name = Some { sym = name; static = false }; off = 0L; index = None }

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

(* the offsets in the data of its addresses, which a PIE loader slides
 * (goken's liblk/macho.c machorebase) *)
let pointers t =
  List.filter_map (fun d ->
    match d.value with
    | Asm.Addr { name = Some n; _ } when d.dsym.kind = Data ->
        let s = sym_of t d.dversion n in
        if s.kind = Undefined then None else Some (d.dsym.value + d.off)
    | _ -> None) t.datas
  |> List.sort compare

let entry t name =
  match Hashtbl.find_opt t.syms (name, 0) with
  | Some { kind = Text; value; _ } -> value
  | _ -> error "entry %s: not defined" name
