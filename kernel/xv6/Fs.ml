(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Fs.mli *)

open Types

module Phys = Machine.Phys

(*****************************************************************************)
(* The disk *)
(*****************************************************************************)

let base = Machine.fs_base ()
let magic = 0x10203040

(* the block size, the disk's: where block 1, the superblock, starts
 * (block 0 is empty). xv6's ports differ (arm-pi1's 512, arm64-pi4's
 * 1024: each fork's driver's), their format otherwise the same *)
let bsize =
  if Phys.get32 (base + 512) = magic then 512
  else if Phys.get32 (base + 1024) = magic then 1024
  else Machine.panic "fs: not an xv6 file system"

(* fs.h, param.h *)
let ndirect = 58
let nindirect = bsize / 4
let maxfile = ndirect + nindirect
let ipb = bsize / 256                       (* inodes per block: a dinode is 256 bytes *)
let dirsiz = 14
let rootino = 1
let ninode = 50

let block b = base + (b * bsize)

(* the superblock, block 1: magic, size, nblocks, ninodes, nlog,
 * logstart, inodestart, bmapstart *)
let sb k = Phys.get32 (block 1 + (4 * k))
let fsize = sb 1
let ninodes = sb 3
let inodestart = sb 6
let bmapstart = sb 7

(*****************************************************************************)
(* An inode's fields, on the disk *)
(*****************************************************************************)

(* a dinode: short type, major, minor, nlink (ownerid, groupid, mode:
 * amd64-jserv's), uint size at 16, addrs at 20 *)
type field = Half of int | Word of int

let i_type = Half 0
let i_major = Half 2
let i_minor = Half 4
let i_nlink = Half 6
let i_size = Word 16
let i_addr k = Word (20 + (4 * k))          (* k = ndirect: the indirect block *)

let dinode inum = block ((inum / ipb) + inodestart) + ((inum mod ipb) * 256)

let get ip f =
  match f with
  | Half o -> Phys.get16 (dinode ip.inum + o)
  | Word o -> Phys.get32 (dinode ip.inum + o)

let set ip f v =
  match f with
  | Half o -> Phys.set16 (dinode ip.inum + o) v
  | Word o -> Phys.set32 (dinode ip.inum + o) v

let itype ip = match get ip i_type with 1 -> Dir | 2 -> File | 3 -> Devnode | _ -> Free
let set_itype ip t = set ip i_type (match t with Free -> 0 | Dir -> 1 | File -> 2 | Devnode -> 3)

(*****************************************************************************)
(* Blocks *)
(*****************************************************************************)

(* a block's bit in the bitmap: its byte's address, the mask *)
let bit b = block ((b / (bsize * 8)) + bmapstart) + ((b mod (bsize * 8)) / 8), 1 lsl (b mod 8)

(* the first free block, marked used, zeroed *)
let balloc () =
  let rec go b =
    if b >= fsize then Machine.panic "balloc: out of blocks"
    else
      let a, m = bit b in
      if Phys.get8 a land m = 0 then begin
        Phys.set8 a (Phys.get8 a lor m);
        Phys.zero (block b) bsize;
        b
      end
      else go (b + 1) in
  go 0

let bfree b =
  let a, m = bit b in
  if Phys.get8 a land m = 0 then Machine.panic "freeing free block";
  Phys.set8 a (Phys.get8 a land lnot m)

(* the disk block holding the file's block [bn], allocated if none yet *)
let bmap ip bn =
  let ensure read write = match read () with 0 -> let b = balloc () in write b; b | b -> b in
  if bn < ndirect then ensure (fun () -> get ip (i_addr bn)) (set ip (i_addr bn))
  else if bn < maxfile then begin
    let ind = ensure (fun () -> get ip (i_addr ndirect)) (set ip (i_addr ndirect)) in
    let e = block ind + (4 * (bn - ndirect)) in
    ensure (fun () -> Phys.get32 e) (Phys.set32 e)
  end
  else Machine.panic "bmap: out of range"

(* the file's blocks all freed, its size 0 *)
let itrunc ip =
  for k = 0 to ndirect - 1 do
    let b = get ip (i_addr k) in
    if b <> 0 then begin bfree b; set ip (i_addr k) 0 end
  done;
  let ind = get ip (i_addr ndirect) in
  if ind <> 0 then begin
    for j = 0 to nindirect - 1 do
      let b = Phys.get32 (block ind + (4 * j)) in
      if b <> 0 then bfree b
    done;
    bfree ind;
    set ip (i_addr ndirect) 0
  end;
  set ip i_size 0

(*****************************************************************************)
(* Inodes in use *)
(*****************************************************************************)

(* xv6's icache, its slots the inodes held: NINODE at most *)
let icache : inode list ref = ref []

let iget inum =
  match List.filter (fun ip -> ip.inum = inum) !icache with
  | ip :: _ -> ip.iref <- ip.iref + 1; ip
  | [] ->
      if List.length !icache >= ninode then Machine.panic "iget: no inodes";
      let ip = { inum = inum; iref = 1 } in
      icache := ip :: !icache;
      ip

let idup ip = ip.iref <- ip.iref + 1; ip

(* the last reference to an inode no directory names: the inode freed *)
let iput ip =
  if ip.iref = 1 && get ip i_nlink = 0 then begin
    itrunc ip;
    set_itype ip Free
  end;
  ip.iref <- ip.iref - 1;
  if ip.iref = 0 then icache := List.filter (fun i -> i != ip) !icache

(* a free inode made [t] *)
let ialloc t =
  let rec go inum =
    if inum >= ninodes then Machine.panic "ialloc: no inodes"
    else if itype { inum = inum; iref = 0 } = Free then begin
      Phys.zero (dinode inum) 256;
      let ip = iget inum in
      set_itype ip t;
      ip
    end
    else go (inum + 1) in
  go 1

(*****************************************************************************)
(* An inode's bytes *)
(*****************************************************************************)

(* [n] bytes at [off], fewer at the end, none past it (xv6-riscv's
 * readi: 0, not -1) *)
let readi ip off n =
  let size = get ip i_size in
  if off > size then Some ""
  else if off < 0 || n < 0 then None
  else begin
    let n = min n (size - off) in
    let b = Buffer.create n in
    let rec go off k =
      if k > 0 then begin
        let m = min k (bsize - (off mod bsize)) in
        Buffer.add_string b (Phys.read (block (bmap ip (off / bsize)) + (off mod bsize)) m);
        go (off + m) (k - m)
      end in
    go off n;
    Some (Buffer.contents b)
  end

(* [s] written at [off], the file grown: its length, or -1 (a hole, or
 * past MAXFILE) *)
let writei ip off s =
  let n = String.length s in
  if off < 0 || off > get ip i_size || off + n > maxfile * bsize then -1
  else begin
    let rec go off i =
      if i < n then begin
        let m = min (n - i) (bsize - (off mod bsize)) in
        Phys.write (block (bmap ip (off / bsize)) + (off mod bsize)) (String.sub s i m);
        go (off + m) (i + m)
      end in
    go off 0;
    if n > 0 && off + n > get ip i_size then set ip i_size (off + n);
    n
  end

(* xv6-riscv's readi to the user (a read(2)): [n] bytes at [off], a
 * block's piece at a time to [dst] (the user's buffer, by offset): the
 * bytes read, or -1 when [dst] cannot take one (the pieces before it
 * copied). [n] a C uint: a negative count wraps, past the end (0) or to
 * the whole file *)
let readi_to ip off n dst =
  let size = get ip i_size in
  if off > size || (n < 0 && off + n >= 0) then 0
  else begin
    let n = if n < 0 then size - off else min n (size - off) in
    let rec go tot off =
      if tot >= n then tot
      else begin
        let m = min (n - tot) (bsize - (off mod bsize)) in
        if dst tot (Phys.read (block (bmap ip (off / bsize)) + (off mod bsize)) m) then go (tot + m) (off + m) else -1
      end in
    go 0 off
  end

(* xv6-riscv's writei from the user: [n] bytes from [src] at [off], a
 * block's piece at a time, stopping at one [src] cannot give; the bytes
 * written, the file grown to them; -1 past the end, past MAXFILE, or a
 * negative (a C uint: huge) count *)
let writei_from ip off n src =
  if n < 0 || off > get ip i_size || off + n > maxfile * bsize then -1
  else begin
    let rec go tot off =
      if tot >= n then tot
      else begin
        let m = min (n - tot) (bsize - (off mod bsize)) in
        match src tot m with
        | None -> tot
        | Some s -> Phys.write (block (bmap ip (off / bsize)) + (off mod bsize)) s; go (tot + m) (off + m)
      end in
    let tot = go 0 off in
    if off + tot > get ip i_size then set ip i_size (off + tot);
    tot
  end

(* struct stat: int dev, uint ino, short type, short nlink, then at 16
 * uint64 size; its padding (12-15) the user's, untouched *)
let stat_head ip =
  Machine.le32 1 ^ Machine.le32 ip.inum ^ Machine.le16 (get ip i_type) ^ Machine.le16 (get ip i_nlink)
let stat_size ip = Machine.le32 (get ip i_size) ^ Machine.le32 0

(*****************************************************************************)
(* Directories *)
(*****************************************************************************)

(* a dirent: ushort inum, 14 bytes of name (NUL-padded, or not ended) *)
let dirent_inum s o = Char.code s.[o] lor (Char.code s.[o + 1] lsl 8)
let dirent_name s o =
  let rec len k = if k < dirsiz && s.[o + 2 + k] <> '\000' then len (k + 1) else k in
  String.sub s (o + 2) (len 0)

let entries dp = match readi dp 0 (get dp i_size) with Some s -> s | None -> ""

(* [name]'s inode (held), and its entry's offset *)
let dirlookup dp name =
  let s = entries dp in
  let rec go off =
    if off + 16 > String.length s then None
    else if dirent_inum s off <> 0 && dirent_name s off = name then Some (iget (dirent_inum s off), off)
    else go (off + 16) in
  go 0

(* a new entry, in the first free one or at the end; -1 if [name] is
 * there *)
let dirlink dp name inum =
  match dirlookup dp name with
  | Some (ip, _) -> iput ip; -1
  | None ->
      let s = entries dp in
      let rec free off = if off + 16 > String.length s || dirent_inum s off = 0 then off else free (off + 16) in
      let padded = name ^ String.make (dirsiz - String.length name) '\000' in
      if writei dp (free 0) (Machine.le16 inum ^ padded) <> 16 then Machine.panic "dirlink";
      0

(* only "." and ".." *)
let isdirempty dp =
  let s = entries dp in
  let rec go off = off + 16 > String.length s || (dirent_inum s off = 0 && go (off + 16)) in
  go 32

(*****************************************************************************)
(* Paths *)
(*****************************************************************************)

(* the element at [i] (its first 14 bytes: DIRSIZ) and where the next
 * starts, the slashes skipped; None at the end *)
let skipelem path i =
  let n = String.length path in
  let rec skip i = if i < n && path.[i] = '/' then skip (i + 1) else i in
  let rec stop j = if j < n && path.[j] <> '/' then stop (j + 1) else j in
  let i = skip i in
  if i = n then None
  else
    let j = stop i in
    Some (String.sub path i (min (j - i) dirsiz), skip j)

(* the path's inode, or ([parent]) its directory's and its last name:
 * held; from the root or the process's directory *)
let namex path parent =
  let start = if String.length path > 0 && path.[0] = '/' then iget rootino else idup (Proc.myproc ()).cwd in
  let rec go ip i =
    match skipelem path i with
    | None -> if parent then begin iput ip; None end else Some (ip, "")
    | Some (name, j) ->
        if itype ip <> Dir then begin iput ip; None end
        else if parent && j = String.length path then Some (ip, name)
        else match dirlookup ip name with
          | None -> iput ip; None
          | Some (next, _) -> iput ip; go next j in
  go start 0

let namei path = match namex path false with Some (ip, _) -> Some ip | None -> None
let nameiparent path = namex path true

(*****************************************************************************)
(* Operations on names (sysfile.c's) *)
(*****************************************************************************)

(* the inode at [path], made [t] if new (held); an existing file does for
 * a file, nothing else does *)
let create path t major minor =
  match nameiparent path with
  | None -> None
  | Some (dp, name) ->
      match dirlookup dp name with
      | Some (ip, _) ->
          iput dp;
          if t = File && (itype ip = File || itype ip = Devnode) then Some ip else begin iput ip; None end
      | None ->
          let ip = ialloc t in
          set ip i_major major;
          set ip i_minor minor;
          set ip i_nlink 1;
          if t = Dir then begin
            (* ".." names the parent; "." does not count (no cycle) *)
            set dp i_nlink (get dp i_nlink + 1);
            if dirlink ip "." ip.inum < 0 || dirlink ip ".." dp.inum < 0 then Machine.panic "create dots"
          end;
          if dirlink dp name ip.inum < 0 then Machine.panic "create: dirlink";
          iput dp;
          Some ip

let link old new_ =
  match namei old with
  | None -> -1
  | Some ip when itype ip = Dir -> iput ip; -1
  | Some ip ->
      set ip i_nlink (get ip i_nlink + 1);
      let ok = match nameiparent new_ with
        | None -> false
        | Some (dp, name) -> let r = dirlink dp name ip.inum in iput dp; r = 0 in
      if not ok then set ip i_nlink (get ip i_nlink - 1);
      iput ip;
      if ok then 0 else -1

let unlink path =
  match nameiparent path with
  | None -> -1
  | Some (dp, name) ->
      let r =
        if name = "." || name = ".." then -1
        else match dirlookup dp name with
          | None -> -1
          | Some (ip, off) ->
              if get ip i_nlink < 1 then Machine.panic "unlink: nlink < 1";
              if itype ip = Dir && not (isdirempty ip) then begin iput ip; -1 end
              else begin
                if writei dp off (String.make 16 '\000') <> 16 then Machine.panic "unlink: writei";
                if itype ip = Dir then set dp i_nlink (get dp i_nlink - 1);
                set ip i_nlink (get ip i_nlink - 1);
                iput ip;
                0
              end in
      iput dp;
      r
