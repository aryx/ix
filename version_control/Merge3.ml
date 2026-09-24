(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Merge3.mli *)

let merge ~(left : Diff.file) ~(base : Diff.file) ~(right : Diff.file) =
  let l = Diff.compute Exact base left and r = Diff.compute Exact base right in
  let base_lines = Diff.lines0 l in
  let llen0 = Array.length base_lines and llen1 = Array.length (Diff.lines1 l) in
  let rlen0 = llen0 and rlen1 = Array.length (Diff.lines1 r) in
  (* collect: the changes backward, then sorted by their first base line *)
  let collect d = Array.of_list (List.stable_sort (fun (a : Diff.change) b -> compare a.oldx b.oldx) (Diff.changes_backward d)) in
  let lc = collect l and rc = collect r in
  let b = Buffer.create 1024 in
  let fetch lines ~maxb a bb = Diff.fetch b lines ~maxb a bb "" in
  let same (x : Diff.change) (y : Diff.change) =
    x.newy - x.newx = y.newy - y.newx
    && (let ok = ref true in
        for i = 0 to x.newy - x.newx do
          if (Diff.lines1 l).(x.newx - 1 + i) <> (Diff.lines1 r).(y.newx - 1 + i) then ok := false
        done;
        !ok) in
  let il = ref 0 and ir = ref 0 and ln = ref 0 and conflict = ref false in
  let overlaps lx ly rx ry = if lx <= rx then ly >= rx else ry >= lx in
  while !il < Array.length lc || !ir < Array.length rc do
    let cur a i = if i < Array.length a then Some a.(i) else None in
    let bounds = function
      | Some (c : Diff.change) -> min c.oldx c.oldy, max c.oldx c.oldy
      | None -> -1, -1 in
    let lcur = cur lc !il and rcur = cur rc !ir in
    let lx, ly = bounds lcur and rx, ry = bounds rcur in
    match lcur, rcur with
    | Some lch, Some rch when overlaps lx ly rx ry ->
        (* the edges aligned, so that same-sized chunks are compared *)
        let lch = ref lch and rch = ref rch in
        if !lch.oldx < !rch.oldx then begin
          let delta = !rch.oldx - !lch.oldx in
          rch := { !rch with oldx = max (!rch.oldx - delta) 1; newx = max (!rch.newx - delta) 1 }
        end
        else begin
          let delta = !lch.oldx - !rch.oldx in
          lch := { !lch with oldx = max (!lch.oldx - delta) 1; newx = max (!lch.newx - delta) 1 }
        end;
        if !lch.oldy > !rch.oldy then begin
          let delta = !lch.oldy - !rch.oldy in
          rch := { !rch with oldy = min (!rch.oldy + delta) rlen0; newy = min (!rch.newy + delta) rlen1 }
        end
        else begin
          let delta = !rch.oldy - !lch.oldy in
          lch := { !lch with oldy = min (!lch.oldy + delta) llen0; newy = min (!lch.newy + delta) llen1 }
        end;
        let lch = !lch and rch = !rch in
        fetch base_lines ~maxb:llen0 !ln (lch.oldx - 1);
        if same lch rch then fetch (Diff.lines1 l) ~maxb:llen1 lch.newx lch.newy
        else begin
          Printf.bprintf b "<<<<<<<<<< %s\n" left.name;
          fetch (Diff.lines1 l) ~maxb:llen1 lch.newx lch.newy;
          Buffer.add_string b "========== original\n";
          fetch base_lines ~maxb:llen0 lch.oldx lch.oldy;
          Printf.bprintf b "========== %s\n" right.name;
          fetch (Diff.lines1 r) ~maxb:rlen1 rch.newx rch.newy;
          Buffer.add_string b ">>>>>>>>>>\n";
          conflict := true
        end;
        ln := lch.oldy + 1;
        incr il;
        incr ir
    | Some lch, _ when rcur = None || lx < rx ->
        fetch base_lines ~maxb:llen0 !ln (lch.oldx - 1);
        fetch (Diff.lines1 l) ~maxb:llen1 lch.newx lch.newy;
        ln := lch.oldy + 1;
        incr il
    | _, Some rch ->
        (* the C bounds these base lines by the first diff's second
         * file: fetch(l, r->ixold, ...) *)
        fetch base_lines ~maxb:llen1 !ln (rch.oldx - 1);
        fetch (Diff.lines1 r) ~maxb:rlen1 rch.newx rch.newy;
        ln := rch.oldy + 1;
        incr ir
    | _ -> assert false
  done;
  if !ln <= llen0 then fetch base_lines ~maxb:llen0 !ln llen0;
  Buffer.contents b, !conflict
