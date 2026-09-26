(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Devdraw.mli *)

open Types

(*****************************************************************************)
(* The files *)
(*****************************************************************************)

(* a qid's path: the file's kind in 4 bits, above them its client's slot
 * + 1 (0: none) *)
let qtopdir = 0 and q2nd = 1 and q3rd = 2 and qnew = 3 and qwinname = 4
let qctl = 5 and qdata = 6 and qcolormap = 7 and qrefresh = 8
let qshift = 4
let kind (q : qid) = q.path land 15

(* the errors (drawerror.c) *)
let enodrawimage = "unknown id for draw image"
let enodrawscreen = "unknown id for draw screen"
let eshortdraw = "short draw message"
let eshortread = "draw read too short"
let eimageexists = "image id in use"
let escreenexists = "screen id in use"
let edrawmem = "image memory allocation failed"
let ereadoutside = "readimage outside image"
let ewriteoutside = "writeimage outside image"
let enotfont = "image not a font"
let eindex = "character index out of range"
let enoclient = "no such draw client"
let enameused = "image name in use"
let enoname = "no image with that name"
let eoldname = "named image no longer valid"
let enamed = "image already has name"
let ewrongname = "wrong name for image"

let error s = raise (Error s)

(*****************************************************************************)
(* The clients, their images, the names, the screens *)
(*****************************************************************************)

(* a font's character in its image (FChar): its rectangle there, where
 * its baseline starts, how far it goes *)
type fchar = { mutable fminx : int; mutable fmaxx : int; mutable fminy : int; mutable fmaxy : int;
               mutable fleft : int; mutable fwidth : int }

(* a client's image (DImage): its number, its pixels, its screen when a
 * window; a font's characters; the named image it is (its name and
 * that name's version then); how many hold it *)
type dimage = {
  did : int;
  dimg : Draw.image;
  dscreen : dscreen option;
  mutable fchars : fchar array;
  mutable ascent : int;
  mutable iname : string option;
  mutable fromname : dimage option;
  mutable ivers : int;
  mutable iref : int;
}
(* a screen windows are made on (DScreen): its image and its fill, who
 * made it, whether others may use it *)
and dscreen = {
  sid : int;
  sdimage : dimage;
  sdfill : dimage;
  spublic : bool;
  sowner : client;
  mscreen : Draw.memscreen;
  mutable dsref : int;
}
(* a client (Client): its images by number (32 buckets, the newest
 * first), the op of its next drawing, the screens it uses, which
 * image its ctl tells of next, what its next data read gets, its
 * windows' parts to redraw (Refresh: the newest first) *)
and client = {
  clientid : int;
  slot : int;
  buckets : dimage list array;
  mutable op : int;
  mutable cscreens : dscreen list;
  mutable infoid : int;
  mutable readdata : string option;
  mutable refreshes : (dimage * int array) list;
  mutable refreshme : bool;
  mutable busy : bool;
  mutable clref : int;
}

(* a name (DName): the image, its client (none: the screen's), its
 * version *)
type dname = { nname : string; nclient : client option; ndimage : dimage; nvers : int }

let nhash = 32
let soverd = 11 and s_op = 10
let refbackup = 0 and refnone = 1 and refmesg = 2

let clients = ref [||]
let lastclientid = ref 0
(* in the order made *)
let names = ref []
let lastvers = ref 0
(* the newest first *)
let dscreens = ref []
let screenimage = ref None
let screenname = ref ""
let screennameid = ref 0
(* the windows refreshed by messages (Refx): their client and image,
 * by the number their layer keeps *)
let refxs = ref []
let lastrefx = ref 0
let drawdebug = ref 0

(* drawname.c *)
let lookupname s = try Some (List.find (fun n -> n.nname = s) !names) with Not_found -> None

let rec goodname d =
  (match d.dscreen with
   | Some ds -> goodname ds.sdimage && goodname ds.sdfill
   | None -> true)
  && (match d.iname with
      | None -> true
      | Some s -> (match lookupname s with Some n -> n.nvers = d.ivers | None -> false))

let addname cl di s =
  if lookupname s <> None then error enameused;
  incr lastvers;
  names := !names @ [ { nname = s; nclient = cl; ndimage = di; nvers = !lastvers } ]

let delname n = names := List.filter (fun m -> m != n) !names

(* drawlookup *)
let lookup cl id checkname =
  match (try Some (List.find (fun d -> d.did = id) cl.buckets.(id land (nhash - 1))) with Not_found -> None) with
  | Some d when checkname && not (goodname d) -> error eoldname
  | r -> r

(* drawalloc.c *)
let install cl id img ds =
  let d = { did = id; dimg = img; dscreen = ds; fchars = [||]; ascent = 0; iname = None; fromname = None;
            ivers = 0; iref = 1 } in
  let b = id land (nhash - 1) in
  cl.buckets.(b) <- d :: cl.buckets.(b);
  d

let rec freedimage d =
  d.iref <- d.iref - 1;
  if d.iref < 0 then Devcons.print "negative ref in drawfreedimage\n";
  if d.iref <= 0 then begin
    names := List.filter (fun n -> n.ndimage != d) !names;
    match d.fromname, d.dscreen with
    | Some f, _ -> freedimage f
    | None, Some ds ->
        let refx = (Draw.layerinfo d.dimg).(0) in
        if refx <> 0 then refxs := List.filter (fun (k, _) -> k <> refx) !refxs;
        Draw.lfree d.dimg (goodname d);
        freedscreen ds
    | None, None -> Draw.free d.dimg
  end

(* drawwindow.c *)
and freedscreen ds =
  ds.dsref <- ds.dsref - 1;
  if ds.dsref < 0 then Devcons.print "negative ref in drawfreedscreen\n";
  if ds.dsref <= 0 then begin
    if not (List.memq ds !dscreens) then error enodrawimage;
    dscreens := List.filter (fun x -> x != ds) !dscreens;
    freedimage ds.sdimage;
    freedimage ds.sdfill;
    Draw.freememscreen ds.mscreen
  end

let uninstall cl id =
  let b = id land (nhash - 1) in
  match (try Some (List.find (fun d -> d.did = id) cl.buckets.(b)) with Not_found -> None) with
  | None -> error enodrawimage
  | Some d ->
      cl.buckets.(b) <- List.filter (fun x -> x != d) cl.buckets.(b);
      freedimage d

let lookupdscreen id = try Some (List.find (fun ds -> ds.sid = id) !dscreens) with Not_found -> None

let lookupscreen cl id = try List.find (fun ds -> ds.sid = id) cl.cscreens with Not_found -> error enodrawscreen

(* drawinstallscreen: a new screen (none given), or one more user of ds *)
let installscreen cl ds id dimage dfill public =
  let ds = match ds with
    | Some ds -> ds
    | None ->
        let ms = Draw.memscreen dimage.dimg dfill.dimg in
        dimage.iref <- dimage.iref + 1;
        dfill.iref <- dfill.iref + 1;
        let ds = { sid = id; sdimage = dimage; sdfill = dfill; spublic = public; sowner = cl; mscreen = ms; dsref = 0 } in
        dscreens := ds :: !dscreens;
        ds in
  ds.dsref <- ds.dsref + 1;
  cl.cscreens <- ds :: cl.cscreens

(* its first use of ds *)
let uninstallscreen cl ds =
  let rec drop = function [] -> [] | x :: rest -> if x == ds then rest else x :: drop rest in
  cl.cscreens <- drop cl.cscreens;
  freedscreen ds

(* drawmisc.c: a window's screen's owner told to redraw it *)
let refreshscreen l cl =
  let rec up = function Some d when d.dscreen = None -> up d.fromname | l -> l in
  match up l with
  | Some { dscreen = Some ds } when ds.sowner != cl -> ds.sowner.refreshme <- true
  | _ -> ()

(* drawrefresh (a layer's, called back by draw9.c): r of a window to
 * redraw, merged with what it had *)
let refresh (refx, x0, y0, x1, y1) =
  match (try Some (List.assoc refx !refxs) with Not_found -> None) with
  | None -> ()
  | Some (c, d) ->
      match (try Some (List.find (fun (d', _) -> d' == d) c.refreshes) with Not_found -> None) with
      | Some (_, r) ->
          if r.(0) > x0 then r.(0) <- x0;
          if r.(1) > y0 then r.(1) <- y0;
          if r.(2) < x1 then r.(2) <- x1;
          if r.(3) < y1 then r.(3) <- y1
      | None -> c.refreshes <- (d, [| x0; y0; x1; y1 |]) :: c.refreshes

let wakeall () =
  Array.iter (function
    | Some cl when cl.refreshme || cl.refreshes <> [] -> Proc.wakeup (Draw_refresh cl.clientid)
    | _ -> ()) !clients

(* drawnewclient: in the first free slot *)
let newclient () =
  let n = Array.length !clients in
  let rec free i = if i = n || !clients.(i) = None then i else free (i + 1) in
  let i = free 0 in
  if i = n then clients := Array.append !clients [| None |];
  incr lastclientid;
  let cl = { clientid = !lastclientid; slot = i; buckets = Array.make nhash []; op = soverd; cscreens = [];
             infoid = 0; readdata = None; refreshes = []; refreshme = false; busy = false; clref = 0 } in
  !clients.(i) <- Some cl;
  cl

let clientofpath path =
  let slot = path lsr qshift in
  if slot = 0 || slot > Array.length !clients then None else !clients.(slot - 1)

let drawclient (c : chan) = match clientofpath c.qid.path with Some cl -> cl | None -> error enoclient

(* drawinit.c: the screen, named for the clients (makescreenimage, the
 * first attach); the mouse told of it *)
let initscreenimage () =
  if !screenimage = None && Swconsole.rect () <> None then begin
    let img = Draw.screenimage () in
    let di = { did = 0; dimg = img; dscreen = None; fchars = [||]; ascent = 0; iname = None; fromname = None;
               ivers = 0; iref = 1 } in
    incr screennameid;
    screenname := "noborder.screen." ^ string_of_int !screennameid;
    addname None di !screenname;
    screenimage := Some img;
    Devmouse.resize ()
  end;
  !screenimage <> None

(*****************************************************************************)
(* The messages (drawmesg.c) *)
(*****************************************************************************)

let byte s i = Char.code s.[i]
let bgshort s i = byte s i lor (byte s (i + 1) lsl 8)
(* BGLONG: signed (a Pi1 int's 31 bits: beyond +-2^30 it wraps; the
 * words with bits 30 and 31 of their own, chans and colours, are read
 * as halves) *)
let bglong s i =
  let b3 = byte s (i + 3) in
  bgshort s i lor (byte s (i + 2) lsl 16) lor ((if b3 >= 128 then b3 - 256 else b3) lsl 24)

let rectinrect r s = s.(0) <= r.(0) && r.(2) <= s.(2) && s.(1) <= r.(1) && r.(3) <= s.(3)

(* the op of a client's next drawing: its 'O', once *)
let clientop cl = let op = cl.op in cl.op <- soverd; op

let drawimage cl s i =
  match lookup cl (bglong s i) true with Some d -> d.dimg | None -> error enodrawimage

(* an image's rectangle, its clip *)
let rect_of img = let (_, a) = Draw.info img in Array.sub a 3 4
let clipr_of img = let (_, a) = Draw.info img in Array.sub a 7 4

(* drawchar: a font's character ci at p, from src at sp; the point
 * after it, sp moved on *)
let drawchar dst (px, py) src sp font ci op =
  let fc = font.fchars.(ci) in
  let x0 = px + fc.fleft and y0 = py - (font.ascent - fc.fminy) in
  let r = [| x0; y0; x0 + (fc.fmaxx - fc.fminx); y0 + (fc.fmaxy - fc.fminy) |] in
  let (sx, sy) = !sp in
  Draw.drawop dst src font.dimg (Array.concat [ r; [| sx + fc.fleft; sy + fc.fminy; fc.fminx; fc.fminy; op |] ]);
  sp := (sx + fc.fwidth, sy);
  (px + fc.fwidth, py)

(* drawcoord: a polygon's coordinate (7 bits, a delta from the last;
 * or 23, absolute) at u; it and the next u *)
let coord a n u old =
  if u >= n then error eshortdraw;
  let b = byte a u in
  let x = b land 0x7F in
  if b land 0x80 <> 0 then begin
    if u + 2 >= n then error eshortdraw;
    let x = x lor (byte a (u + 1) lsl 7) lor (byte a (u + 2) lsl 15) in
    ((if x land (1 lsl 22) <> 0 then x lor ((-1) lsl 23) else x), u + 3)
  end
  else ((if b land 0x40 <> 0 then x lor ((-1) lsl 7) else x) + old, u + 1)

let drawmesg cl a =
  let n = String.length a in
  let pos = ref 0 in
  while !pos < n do
    let p = !pos in
    let short m = if n - p < m then error eshortdraw in
    let l i = bglong a (p + i) and sh i = bgshort a (p + i) and b i = byte a (p + i) in
    let pt i = [| l i; l (i + 4) |] and rect i = [| l i; l (i + 4); l (i + 8); l (i + 12) |] in
    let m =
      match a.[p] with
      (* allocate: 'b' id[4] screenid[4] refresh[1] chan[4] repl[1] R[4*4] clipR[4*4] rrggbbaa[4] *)
      | 'b' ->
          short 51;
          let dstid = l 1 and scrnid = sh 5 and refresh = b 9 and chan = [| sh 12; sh 10 |] and repl = b 14 in
          let r = rect 15 and clipr = rect 31 and value = [| sh 49; sh 47 |] in
          if lookup cl dstid false <> None then error eimageexists;
          if scrnid <> 0 then begin
            let ds = lookupscreen cl scrnid in
            let (hi, lo) = Draw.memscreenchan ds.mscreen in
            if repl <> 0 || chan.(0) <> hi || chan.(1) <> lo then error "image parameters incompatible with screen";
            if refresh <> refbackup && refresh <> refnone && refresh <> refmesg then error "unknown refresh method";
            let w = Draw.lalloc ds.mscreen (Array.concat [ r; [| refresh |]; clipr; value ]) in
            if Draw.isnil w then error edrawmem;
            let di = install cl dstid w (Some ds) in
            ds.dsref <- ds.dsref + 1;
            if refresh = refmesg then begin
              if not (goodname di) then error eoldname;
              incr lastrefx;
              refxs := (!lastrefx, (cl, di)) :: !refxs;
              Draw.lsetrefresh w !lastrefx
            end
            else if refresh = refnone then Draw.lsetrefresh w 0
          end
          else begin
            let i = Draw.allocimage (Array.concat [ r; chan; [| repl |]; clipr; value ]) in
            if Draw.isnil i then error edrawmem;
            ignore (install cl dstid i None)
          end;
          51
      (* free: 'f' id[4] *)
      | 'f' ->
          short 5;
          (match lookup cl (l 1) false with
           | Some { dscreen = Some ds } when ds.sowner != cl -> ds.sowner.refreshme <- true
           | _ -> ());
          uninstall cl (l 1);
          5
      (* repl and clip: 'c' dstid[4] repl[1] clipR[4*4] *)
      | 'c' ->
          short 22;
          (match lookup cl (l 1) true with
           | None -> error enodrawimage
           | Some d ->
               if d.iname <> None then error "cannot change repl/clipr of shared image";
               if b 5 <> 0 then Draw.setrepl d.dimg;
               Draw.setclipr d.dimg (rect 6));
          22
      (* visible: 'v' (a flush, nothing on the Pi) *)
      | 'v' -> 1
      (* name an image: 'N' dstid[4] in[1] j[1] name[j] *)
      | 'N' ->
          short 7;
          let c = b 5 and j = b 6 in
          if j = 0 then error eshortdraw;
          short (7 + j);
          let s = String.sub a (p + 7) j in
          (match lookup cl (l 1) false with
           | None -> error enodrawimage
           | Some di ->
               if di.iname <> None then error enamed;
               if c <> 0 then addname (Some cl) di s
               else
                 match lookupname s with
                 | None -> error enoname
                 | Some dn -> if dn.ndimage != di then error ewrongname; delname dn);
          7 + j
      (* attach to a named image: 'n' dstid[4] j[1] name[j] *)
      | 'n' ->
          short 6;
          let j = b 5 in
          if j = 0 then error eshortdraw;
          short (6 + j);
          let dstid = l 1 and s = String.sub a (p + 6) j in
          if lookup cl dstid false <> None then error eimageexists;
          (match lookupname s with
           | None -> error enoname
           | Some dn ->
               let di = install cl dstid dn.ndimage.dimg None in
               di.iname <- Some s;
               di.fromname <- Some dn.ndimage;
               dn.ndimage.iref <- dn.ndimage.iref + 1;
               di.ivers <- dn.nvers;
               cl.infoid <- dstid);
          6 + j
      (* draw: 'd' dstid[4] srcid[4] maskid[4] R[4*4] P[2*4] P[2*4] *)
      | 'd' ->
          short 45;
          let dst = drawimage cl a (p + 1) in
          let src = drawimage cl a (p + 5) in
          let mask = drawimage cl a (p + 9) in
          Draw.drawop dst src mask (Array.concat [ rect 13; pt 29; pt 37; [| clientop cl |] ]);
          45
      (* the next drawing's op: 'O' op *)
      | 'O' -> short 2; cl.op <- b 1; 2
      (* line: 'L' dstid[4] p0[2*4] p1[2*4] end0[4] end1[4] radius[4] srcid[4] sp[2*4] *)
      | 'L' ->
          short 45;
          let dst = drawimage cl a (p + 1) in
          let j = l 29 in
          if j < 0 then error "negative line width";
          let src = drawimage cl a (p + 33) in
          Draw.line dst src (Array.concat [ pt 5; pt 13; [| l 21; l 25; j |]; pt 37; [| clientop cl |] ]);
          45
      (* polygon: 'p' dstid[4] n[2] end0[4] end1[4] radius[4] srcid[4] sp[2*4] p0[2*4] dp[2*2*n];
       * filled: 'P' ..., end0 its winding rule *)
      | ('p' | 'P') as k ->
          short 31;
          let dst = drawimage cl a (p + 1) in
          let ni = sh 5 + 1 and e0 = l 7 and e1 = l 11 in
          let j = if k = 'p' then l 15 else 0 in
          if j < 0 then error "negative polygon line width";
          let src = drawimage cl a (p + 19) in
          let sp = pt 23 in
          let pts = Array.make (2 * ni) 0 in
          let u = ref (p + 31) and ox = ref 0 and oy = ref 0 in
          for y = 0 to ni - 1 do
            let (x, u') = coord a n !u !ox in
            let (yy, u'') = coord a n u' !oy in
            u := u'';
            ox := x;
            oy := yy;
            pts.(2 * y) <- x;
            pts.(2 * y + 1) <- yy
          done;
          ignore (Draw.poly dst src (Array.concat [ [| e0; e1; j |]; sp; [| clientop cl; (if k = 'P' then 1 else 0); ni |]; pts ]));
          !u - p
      (* ellipse: 'e' dstid[4] srcid[4] center[2*4] a[4] b[4] thick[4] sp[2*4] alpha[4] phi[4];
       * filled: 'E'; alpha's bit 31 an arc *)
      | ('e' | 'E') as k ->
          short 45;
          let dst = drawimage cl a (p + 1) in
          let src = drawimage cl a (p + 5) in
          let e0 = l 17 and e1 = l 21 in
          if e0 < 0 || e1 < 0 then error "invalid ellipse semidiameter";
          let j = l 25 in
          if j < 0 then error "negative ellipse thickness";
          let c = if k = 'E' then -1 else j in
          let b3 = b 40 in
          let arc = b3 land 0x80 <> 0 in
          let alpha = if b3 land 0x40 <> 0 then l 37 else ((b3 land 0x3F) lsl 24) lor (sh 37) lor (b 39 lsl 16) in
          Draw.ellipse dst src (Array.concat [ pt 9; [| e0; e1; c |]; pt 29; [| clientop cl; (if arc then 1 else 0); alpha; l 41 |] ]);
          45
      (* string: 's' dstid[4] srcid[4] fontid[4] P[2*4] clipr[4*4] sp[2*4] ni[2] ni*(index[2]);
       * on a background: 'x' ... ni[2] bgid[4] bgpt[2*4] ni*(index[2]) *)
      | ('s' | 'x') as k ->
          let m = if k = 'x' then 59 else 47 in
          short m;
          let dst = drawimage cl a (p + 1) in
          let src = drawimage cl a (p + 5) in
          let font = match lookup cl (l 9) true with Some f -> f | None -> error enodrawimage in
          if Array.length font.fchars = 0 then error enotfont;
          let pp = pt 13 and r = rect 21 and ni = sh 45 in
          let u = p + m in
          short (m + ni * 2);
          let clipr = clipr_of dst in
          Draw.setclipr dst r;
          let op = clientop cl in
          let index i =
            let ci = bgshort a (u + 2 * i) in
            if ci >= Array.length font.fchars then begin Draw.setclipr dst clipr; error eindex end;
            ci in
          let bg =
            if k = 'x' then begin
              let bg = drawimage cl a (p + 47) in
              let fr = rect_of font.dimg in
              let y0 = pp.(1) - font.ascent in
              let x1 = ref pp.(0) in
              for i = 0 to ni - 1 do x1 := !x1 + font.fchars.(index i).fwidth done;
              Draw.drawop dst bg (Draw.opaque ()) (Array.concat [ [| pp.(0); y0; !x1; y0 + (fr.(3) - fr.(1)) |]; pt 51; [| 0; 0; op |] ]);
              bg
            end
            else dst in
          let sp = ref (l 37, l 41) and q = ref (pp.(0), pp.(1)) in
          for i = 0 to ni - 1 do q := drawchar dst !q src sp font (index i) op done;
          Draw.setclipr dst clipr;
          m + ni * 2
      (* a font's character: 'l' fontid[4] srcid[4] index[2] R[4*4] P[2*4] left[1] width[1] *)
      | 'l' ->
          short 37;
          let font = match lookup cl (l 1) true with Some f -> f | None -> error enodrawimage in
          if Array.length font.fchars = 0 then error enotfont;
          let src = drawimage cl a (p + 5) in
          let ci = sh 9 in
          if ci >= Array.length font.fchars then error eindex;
          let r = rect 11 and pp = pt 27 in
          Draw.drawop font.dimg src (Draw.opaque ()) (Array.concat [ r; pp; pp; [| s_op |] ]);
          let fc = font.fchars.(ci) in
          fc.fminx <- r.(0);
          fc.fmaxx <- r.(2);
          fc.fminy <- r.(1) land 0xFF;
          fc.fmaxy <- r.(3) land 0xFF;
          fc.fleft <- (let v = b 35 in if v >= 128 then v - 256 else v);
          fc.fwidth <- b 36;
          37
      (* a font: 'i' fontid[4] nchars[4] ascent[1] *)
      | 'i' ->
          short 10;
          let dstid = l 1 in
          if dstid = 0 then error "cannot use display as font";
          let font = match lookup cl dstid true with Some f -> f | None -> error enodrawimage in
          if (snd (Draw.info font.dimg)).(12) <> 0 then error "cannot use window as font";
          let ni = l 5 in
          if ni <= 0 || ni > 4096 then error "bad font size (4096 chars max)";
          font.fchars <- Array.init ni (fun _ -> { fminx = 0; fmaxx = 0; fminy = 0; fmaxy = 0; fleft = 0; fwidth = 0 });
          font.ascent <- b 9;
          10
      (* pixels: 'y' id[4] R[4*4] data[x*1]; compressed: 'Y' *)
      | ('y' | 'Y') as k ->
          short 21;
          let dst = drawimage cl a (p + 1) in
          let r = rect 5 in
          if not (rectinrect r (rect_of dst)) then error ewriteoutside;
          let y = Draw.memload dst (Array.append r [| (if k = 'Y' then 1 else 0) |]) (String.sub a (p + 21) (n - p - 21)) in
          if y < 0 then error "bad writeimage call";
          21 + y
      (* read: 'r' id[4] R[4*4] (the next data read's) *)
      | 'r' ->
          short 21;
          let i = drawimage cl a (p + 1) in
          let r = rect 5 in
          if not (rectinrect r (rect_of i)) then error ereadoutside;
          cl.readdata <- Some (Draw.unload i r);
          21
      (* a screen: 'A' id[4] imageid[4] fillid[4] public[1] *)
      | 'A' ->
          short 14;
          let dstid = l 1 in
          if dstid = 0 then error ebadarg;
          if lookupdscreen dstid <> None then error escreenexists;
          (match lookup cl (l 5) true, lookup cl (l 9) true with
           | Some ddst, Some dsrc -> installscreen cl None dstid ddst dsrc (b 13 <> 0)
           | _ -> error enodrawimage);
          14
      (* free a screen: 'F' id[4] *)
      | 'F' -> short 5; uninstallscreen cl (lookupscreen cl (l 1)); 5
      (* use a public screen: 'S' id[4] chan[4] *)
      | 'S' ->
          short 9;
          let dstid = l 1 in
          if dstid = 0 then error ebadarg;
          (match lookupdscreen dstid with
           | Some ds when ds.spublic || ds.sowner == cl ->
               if Draw.memscreenchan ds.mscreen <> (sh 7, sh 5) then error "inconsistent chan";
               installscreen cl (Some ds) 0 ds.sdimage ds.sdfill false
           | _ -> error enodrawscreen);
          9
      (* windows to the front or the rear: 't' top[1] nw[2] n*id[4] *)
      | 't' ->
          short 4;
          let nw = sh 2 in
          if nw = 0 then 4
          else begin
            short (4 + nw * 4);
            let lp = Array.init nw (fun j -> drawimage cl a (p + 4 + j * 4)) in
            (match Draw.ltofront lp (b 1 <> 0) with
             | -1 -> error "images are not windows"
             | -2 -> error "images not on same screen"
             | _ -> ());
            refreshscreen (lookup cl (l 4) true) cl;
            4 + nw * 4
          end
      (* a window's origin: 'o' id[4] r.min[2*4] screenr.min[2*4] *)
      | 'o' ->
          short 21;
          let dst = drawimage cl a (p + 1) in
          if (snd (Draw.info dst)).(12) <> 0 then begin
            let ni = Draw.lorigin dst (Array.append (pt 5) (pt 13)) in
            if ni < 0 then error "image origin failed";
            if ni > 0 then refreshscreen (lookup cl (l 1) true) cl
          end;
          21
      (* debugging: 'D' val[1] *)
      | 'D' -> short 2; drawdebug := b 1; 2
      | _ -> error "bad draw command"
    in
    pos := p + m
  done

(*****************************************************************************)
(* The device *)
(*****************************************************************************)

let readstr off n s = if off >= String.length s then "" else String.sub s off (min n (String.length s - off))

let fq path = { path = path; vers = 0; typ = Qt_file }
let dq path = { path = path; vers = 0; typ = Qt_dir }

(* drawgen: a directory's entries (name, qid, perm) *)
let entries (c : chan) =
  let t = kind c.qid in
  if t = qtopdir then [ ("draw", dq q2nd, 0o555); ("winname", fq qwinname, 0o444) ]
  else if t = qwinname then [ ("winname", fq qwinname, 0o444) ]
  else if t = q2nd || t = qnew then
    ("new", fq qnew, 0o666)
    :: List.concat (Array.to_list (Array.mapi (fun i o -> match o with
         | Some cl -> [ (string_of_int cl.clientid, dq (((i + 1) lsl qshift) lor q3rd), 0o555) ]
         | None -> []) !clients))
  else begin
    let base = c.qid.path land (lnot 15) in
    let q k = { path = base lor k; vers = c.qid.vers; typ = Qt_file } in
    [ ("colormap", q qcolormap, 0o600); ("ctl", q qctl, 0o600); ("data", q qdata, 0o600); ("refresh", q qrefresh, 0o400) ]
  end

(* devstat's name for a directory: its path's last element *)
let elem s =
  if s = "/" then s else try let i = String.rindex s '/' in String.sub s (i + 1) (String.length s - i - 1) with Not_found -> s

let pad11 s = String.make (max 0 (11 - String.length s)) ' ' ^ s

(* the ctl's read: the client's number, then an image's (the screen's
 * first: initdisplay's) *)
let ctlinfo cl =
  if cl.infoid < 0 then error enodrawimage;
  let img =
    if cl.infoid = 0 then (match !screenimage with Some i -> i | None -> error enodrawimage)
    else match lookup cl cl.infoid true with Some d -> d.dimg | None -> error enodrawimage in
  let (chan, a) = Draw.info img in
  let s = String.concat "" (List.map (fun v -> pad11 v ^ " ")
    (string_of_int cl.clientid :: string_of_int cl.infoid :: chan :: List.map string_of_int (Array.to_list (Array.sub a 2 9)))) in
  cl.infoid <- -1;
  s

(* the refresh's read: the windows' parts to redraw, 5 words each *)
let rec refreshread cl n =
  if not (cl.refreshme || cl.refreshes <> []) then begin Proc.sleep (Draw_refresh cl.clientid); refreshread cl n end
  else begin
    let b = Buffer.create 64 in
    let rec go n =
      match cl.refreshes with
      | (d, r) :: rest when n >= 20 ->
          Buffer.add_string b (Machine.le32 d.did);
          Array.iter (fun v -> Buffer.add_string b (Machine.le32 v)) r;
          cl.refreshes <- rest;
          go (n - 20)
      | _ -> () in
    go n;
    cl.refreshme <- false;
    Buffer.contents b
  end

(* strtoul(s, 0, 0)'s: a number's value, whether it had digits *)
let strtoul s =
  let n = String.length s in
  let base, i = if n > 1 && s.[0] = '0' && (s.[1] = 'x' || s.[1] = 'X') then 16, 2 else if n > 0 && s.[0] = '0' then 8, 0 else 10, 0 in
  let digit c = match c with '0' .. '9' -> Char.code c - 48 | 'a' .. 'f' -> Char.code c - 87 | 'A' .. 'F' -> Char.code c - 55 | _ -> 99 in
  let rec go i v = if i < n && digit s.[i] < base then go (i + 1) (v * base + digit s.[i]) else (v, i) in
  let (v, j) = go i 0 in
  (v, j > 0)

(* the colormap's write: lines "index red green blue" (no colour map on
 * an RGB16 screen: checked, then nothing); the lines' bytes *)
let colormapwrite s =
  let n = String.length s in
  let rec go pos used =
    if pos >= n then used
    else begin
      let x = min (n - pos) 127 in
      match (try Some (String.index_from s pos '\n') with Not_found -> None) with
      | Some k when k < pos + x ->
          let i = k + 1 - pos in
          let fields = List.filter (fun w -> w <> "") (String.split_on_char ' '
            (String.map (fun c -> if c = '\t' || c = '\n' || c = '\r' then ' ' else c) (String.sub s pos i))) in
          (match fields with
           | [ f0; f1; f2; f3 ] ->
               let (i0, _) = strtoul f0 and (r, _) = strtoul f1 and (g, _) = strtoul f2 and (bl, ok) = strtoul f3 in
               if not ok then error ebadarg;
               if r > 255 || g > 255 || bl > 255 || i0 < 0 || i0 > 255 then error ebadarg
           | _ -> error ebadarg);
          go (pos + i) (used + i)
      | _ -> used
    end in
  go 0 0

let close (c : chan) =
  if kind c.qid >= qctl then begin
    let cl = drawclient c in
    if kind c.qid = qctl then cl.busy <- false;
    if c.opened <> None then begin
      cl.clref <- cl.clref - 1;
      if cl.clref = 0 then begin
        cl.refreshes <- [];
        names := List.filter (fun n -> match n.nclient with Some x -> x != cl | None -> true) !names;
        while cl.cscreens <> [] do uninstallscreen cl (List.hd cl.cscreens) done;
        for i = 0 to nhash - 1 do
          while cl.buckets.(i) <> [] do
            let d = List.hd cl.buckets.(i) in
            cl.buckets.(i) <- List.tl cl.buckets.(i);
            freedimage d
          done
        done;
        !clients.(cl.slot) <- None
      end
    end
  end

let open_ (c : chan) m =
  if c.qid.typ = Qt_dir then ignore (Dev.tab_open c m);
  if kind c.qid = qnew then begin
    let cl = newclient () in
    c.qid <- { c.qid with path = qctl lor ((cl.slot + 1) lsl qshift) }
  end;
  let t = kind c.qid in
  if t = qdata || t = qcolormap || t = qrefresh then begin
    let cl = drawclient c in
    cl.clref <- cl.clref + 1
  end
  else if t = qctl then begin
    let cl = drawclient c in
    if cl.busy then error einuse;
    cl.busy <- true;
    match lookupname !screenname with
    | None -> error "draw: cannot happen 2"
    | Some dn ->
        let di = install cl 0 dn.ndimage.dimg None in
        di.ivers <- dn.nvers;
        di.iname <- Some !screenname;
        di.fromname <- Some dn.ndimage;
        dn.ndimage.iref <- dn.ndimage.iref + 1;
        cl.clref <- cl.clref + 1
  end;
  c

let init () =
  Callback.register "draw_refresh" refresh;
  let d = Dev.default 'i' "draw" in
  Dev.register { d with
    Dev.attach = (fun _ ->
      if not (initscreenimage ()) then error "no frame buffer";
      Dev.attach 'i' 0 (dq qtopdir));
    Dev.walk = (fun c _ name ->
      if !screenimage = None then error "no frame buffer";
      if c.qid.typ <> Qt_dir then error enotdir;
      if name = ".." then (if kind c.qid = q3rd then dq q2nd else dq qtopdir)
      else
        try let (_, q, _) = List.find (fun (nm, _, _) -> nm = name) (entries c) in q
        with Not_found -> error enonexist);
    Dev.stat = (fun c ->
      try
        let (nm, q, perm) = List.find (fun (_, q, _) -> q.path = c.qid.path) (entries c) in
        Dev.mkdir c nm q 0 perm
      with Not_found ->
        if c.qid.typ = Qt_dir then Dev.mkdir c (elem c.cname) c.qid 0 0o555 else error enonexist);
    Dev.dirs = (fun c -> List.map (fun (nm, q, perm) -> Dev.mkdir c nm q 0 perm) (entries c));
    Dev.open_ = open_;
    Dev.close = close;
    Dev.read = (fun c n off ->
      let t = kind c.qid in
      if t = qwinname then readstr off n !screenname
      else begin
        let cl = drawclient c in
        if t = qctl then begin
          if n < 12 * 12 then error eshortread;
          ctlinfo cl
        end
        else if t = qdata then begin
          match cl.readdata with
          | None -> error "no draw data"
          | Some d ->
              if n < String.length d then error eshortread;
              cl.readdata <- None;
              d
        end
        else if t = qcolormap then
          readstr off n (String.concat "" (List.map (fun i -> pad11 (string_of_int i) ^ " " ^ pad11 "0" ^ " " ^ pad11 "0" ^ " " ^ pad11 "0" ^ "\n")
            (List.init 256 (fun i -> i))))
        else if t = qrefresh then begin
          if n < 5 * 4 then error ebadarg;
          refreshread cl n
        end
        else ""
      end);
    Dev.write = (fun c s _ ->
      if c.qid.typ = Qt_dir then error eisdir;
      let cl = drawclient c in
      let t = kind c.qid and n = String.length s in
      if t = qctl then begin
        if n <> 4 then error "unknown draw control request";
        cl.infoid <- bglong s 0;
        n
      end
      else if t = qdata then begin
        (try drawmesg cl s with e -> wakeall (); raise e);
        wakeall ();
        n
      end
      else if t = qcolormap then colormapwrite s
      else error ebadusefd);
  }
