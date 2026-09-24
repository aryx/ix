(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See CLI.mli *)

type caps = < Eval.caps; Cap.argv; Cap.exit >

(* plan9port's rcmain (/usr/lib/plan9/etc/rcmain, as 9base installs it) *)
let rcmain = {|# rcmain: Plan 9 on Unix version
if(~ $#home 0) home=$HOME
if(~ $#home 0) home=/
if(~ $#ifs 0) ifs=IFS
switch($#prompt){
case 0
	prompt=('% ' '	')
case 1
	prompt=($prompt '	')
}
if(~ $rcname ?.out ?.rc */?.rc */?.out) prompt=('broken! ' '	')
if(flag p) path=(/bin /usr/bin)
if not{
	finit
	# should be taken care of by rc now, but leave just in case
}
fn sigexit
if(! ~ $#cflag 0){
	if(flag l && test -r $home/lib/profile) . $home/lib/profile
	status=''
	eval $cflag
	exit $status
}
if(flag i){
	if(flag l && test -r $home/lib/profile) . $home/lib/profile
	status=''
	if(! ~ $#* 0) . $*
	. -i '/dev/stdin'
	exit $status
}
if(flag l && test -r $home/lib/profile) . $home/lib/profile
if(~ $#* 0){
	. /dev/stdin
	exit $status
}
status=''
. $*
exit $status
|}

(* its ifs line is a blank, a tab and a newline, which a {| |} string
 * would not show *)
let rcmain =
  match String.split_on_char '\n' rcmain with
  | lines ->
      String.concat "\n"
        (List.map (fun l -> if l = "if(~ $#ifs 0) ifs=IFS" then "if(~ $#ifs 0) ifs=' \t\n'" else l) lines)

let usage = "usage: rc [-eiIlrvxp] [-c arg] [-m rcmain] [file [arg ...]]"

let main (caps : < caps; .. >) (argv : string array) : int =
  Builtin.init ();
  let env = Env.create () in
  Env.import env (CapUnix.environment caps ());
  let argv0 = if Array.length argv > 0 then argv.(0) else "rc" in
  let main_file = ref None in
  let rec flags = function
    | "-c" :: cmd :: rest -> Env.set env "cflag" [ cmd ]; flags rest
    | "-m" :: file :: rest -> main_file := Some file; flags rest
    | a :: rest when String.length a > 1 && a.[0] = '-' && a <> "--" ->
        String.iteri (fun i c -> if i > 0 then Env.set_flag env c true) a;
        flags rest
    | "--" :: rest -> Some rest
    | rest -> Some rest
  in
  match flags (List.tl (Array.to_list argv)) with
  | None -> prerr_endline usage; 1
  | Some args ->
      Env.set env "*" args;
      Env.set env "rcname" [ argv0 ];
      Env.set env "pid" [ string_of_int (Unix.getpid ()) ];
      if not (Env.flag env 'I') && Env.get env "cflag" = [] && args = [] && Unix.isatty Unix.stdin then
        Env.set_flag env 'i' true;
      Sys.set_signal Sys.sigint (Sys.Signal_handle (fun _ -> Eval.interrupted := true));
      let t = Eval.create caps ~argv0 env in
      let text =
        match !main_file with
        | None -> rcmain
        | Some f -> Files.read caps (Fpath.v f)
      in
      let finish status =
        (* sigexit, if defined, runs once on the way out *)
        (match Env.fn env "sigexit" with
         | Some body ->
             Env.set_fn env "sigexit" None;
             Env.set_status env status;
             (try Eval.run t body with _ -> ())
         | None -> ());
        flush stdout;
        Process.code status
      in
      match Eval.source t ~name:(Some "rcmain") ~interactive:false (Lexer.of_string text) with
      | () -> finish (Env.status env)
      | exception Eval.Exit s -> finish s
      | exception (Eval.Error m | Word.Error m) ->
          if m <> "" then Eval.eprint (Printf.sprintf "rc (%s): %s\n" argv0 m);
          (* claude: an error ends rc without its sigexit, as 9base's *)
          Env.set_fn env "sigexit" None;
          finish "error"
