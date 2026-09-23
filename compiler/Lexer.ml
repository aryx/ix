(* Claude Code
 *
 * Copyright (C) 2026 Yoann Padioleau
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public License
 * (LGPL) as published by the Free Software Foundation; either version
 * 2 of the License, or (at your option) any later version.
 *)
(* See Lexer.mli *)

open Tree
(* claude: the characters, from the input stack *)
open Pre

module P = Parser

(*****************************************************************************)
(* Keywords *)
(*****************************************************************************)

(* a keyword's symbol has its token's index + 1 as lexical *)
let keywords = [ "auto", P.LAUTO; "break", P.LBREAK; "case", P.LCASE; "char", P.LCHAR; "const", P.LCONSTNT;
  "continue", P.LCONTINUE; "default", P.LDEFAULT; "do", P.LDO; "double", P.LDOUBLE; "else", P.LELSE;
  "enum", P.LENUM; "extern", P.LEXTERN; "float", P.LFLOAT; "for", P.LFOR; "goto", P.LGOTO; "if", P.LIF;
  "inline", P.LINLINE; "int", P.LINT; "long", P.LLONG; "register", P.LREGISTER; "restrict", P.LRESTRICT;
  "return", P.LRETURN; "SET", P.LSET; "short", P.LSHORT; "signed", P.LSIGNED; "signof", P.LSIGNOF;
  "sizeof", P.LSIZEOF; "static", P.LSTATIC; "struct", P.LSTRUCT; "switch", P.LSWITCH; "typedef", P.LTYPEDEF;
  "typestr", P.LTYPESTR; "union", P.LUNION; "unsigned", P.LUNSIGNED; "USED", P.LUSED; "void", P.LVOID;
  "volatile", P.LVOLATILE; "while", P.LWHILE ]

let init () =
  Array.fill hash 0 nhash [];
  List.iteri (fun i (k, _) -> (lookup k).lexical <- i + 1) keywords

let ops = [ "->", P.LMG; "++", P.LPP; "--", P.LMM; "<<", P.LLSH; ">>", P.LRSH; "<=", P.LLE; ">=", P.LGE;
  "==", P.LEQ; "!=", P.LNE; "&&", P.LANDAND; "||", P.LOROR; "+=", P.LPE; "-=", P.LME; "*=", P.LMLE;
  "/=", P.LDVE; "%=", P.LMDE; "&=", P.LANDE; "|=", P.LORE; "^=", P.LXORE; "<<=", P.LLSHE; ">>=", P.LRSHE;
  "...", P.LDOTS ]
let op s = List.assoc s ops

let punct c =
  match c with
  | ';' -> P.SEMI | ',' -> P.COMMA | '=' -> P.ASSIGN | '?' -> P.QUESTION | ':' -> P.COLON | '|' -> P.OR
  | '^' -> P.XOR | '&' -> P.AND | '<' -> P.LT | '>' -> P.GT | '+' -> P.PLUS | '-' -> P.MINUS | '*' -> P.STAR
  | '/' -> P.SLASH | '%' -> P.PERCENT | '(' -> P.LPAREN | ')' -> P.RPAREN | '[' -> P.LBRACK | ']' -> P.RBRACK
  | '{' -> P.LBRACE | '}' -> P.RBRACE | '.' -> P.DOT | '!' -> P.NOT | '~' -> P.TILDE
  | c -> error_at !lineno "illegal character: %c" c

(*****************************************************************************)
(* Tokens (lex.c's yylex) *)
(*****************************************************************************)

(* the rune whose UTF-8 starts with c (lex.c's getr) *)
let rune c =
  let n, v = if c land 0xe0 = 0xc0 then 1, c land 0x1f else if c land 0xf0 = 0xe0 then 2, c land 0x0f else 3, c land 0x07 in
  let rec go n v = if n = 0 then v else go (n - 1) ((v lsl 6) lor (getc () land 0x3f)) in
  go n v

(* a character in a string or a constant, or None at its end
 * (lex.c's escchar); an escape gives a byte, not a rune *)
let escchar e longflg =
  let c = getc () in
  if c = 10 then error_at !lineno "newline in string";
  if c <> 92 then (if c = e then None else Some ((if longflg && c >= 0x80 then rune c else c), false))
  else
    let c = getc () in
    if c = 120 then begin
      let rec hex i v =
        if i = 0 then v
        else
          let c = getc () in
          if is_digit c then hex (i - 1) ((v * 16) + c - 48)
          else if c >= 97 && c <= 102 then hex (i - 1) ((v * 16) + c - 87)
          else if c >= 65 && c <= 70 then hex (i - 1) ((v * 16) + c - 55)
          else (unget c; v)
      in
      Some (hex (if longflg then 6 else 2) 0, true)
    end
    else if c >= 48 && c <= 55 then begin
      let rec oct i v = if i = 0 then v else let c = getc () in if c >= 48 && c <= 55 then oct (i - 1) ((v * 8) + c - 48) else (unget c; oct 0 v) in
      Some (oct (if longflg then 8 else 2) (c - 48), true)
    end
    else
      Some ((match chr c with 'n' -> 10 | 't' -> 9 | 'b' -> 8 | 'r' -> 13 | 'f' -> 12 | 'a' -> 7 | 'v' -> 11 | _ -> c), false)

(* a string's bytes: the source's UTF-8 as it is, an escape as a byte *)
let lexstring () =
  let b = Buffer.create 16 in
  let rec go () =
    match escchar 34 false with
    | None -> ()
    | Some (c, _) -> Buffer.add_char b (chr (c land 255)); go ()
  in
  go ();
  Buffer.contents b

(* lex.c's mpatov: decimal, 0 octal, 0x hex; ~0 on overflow *)
let mpatov s =
  let n = String.length s in
  let parse base start =
    let rec go i v =
      if i >= n then Some v
      else
        let c = Char.code s.[i] in
        let d = if is_digit c then c - 48 else if c >= 97 && c <= 102 then c - 87 else if c >= 65 && c <= 70 then c - 55 else 99 in
        if d >= base && base <> 8 then None
        else
          let nv = Int64.add (Int64.mul v (Int64.of_int base)) (Int64.of_int d) in
          if Int64.compare v 0L < 0 && Int64.compare nv 0L >= 0 then None else go (i + 1) nv
    in
    go start 0L
  in
  let r = if n > 1 && s.[0] = '0' then (if s.[1] = 'x' || s.[1] = 'X' then parse 16 2 else parse 8 1) else parse 10 0 in
  match r with Some v -> v | None -> -1L

let number c =
  let b = Buffer.create 16 in
  let add c = Buffer.add_char b (chr c) in
  let rec digits c = if is_digit c then (add c; digits (getc ())) else c in
  let floating c =
    (* the fraction and the exponent (casedot, casee) *)
    let c = if c = 46 then (add c; digits (getc ())) else c in
    let c =
      if c = 101 || c = 69 then begin
        add 101;
        let c = getc () in
        let c = if c = 43 || c = 45 then (add c; getc ()) else c in
        digits c
      end
      else c
    in
    let et, c = if c = 76 || c = 108 then Tdouble, getc () else if c = 70 || c = 102 then Tfloat, getc () else Tdouble, c in
    unget c;
    P.LFCONST (float_of_string (Buffer.contents b), et)
  and integer c =
    let rec suffix c uns lng vlng =
      if (c = 85 || c = 117) && not uns then suffix (getc ()) true lng vlng
      else if (c = 76 || c = 108) && not vlng then suffix (getc ()) uns true lng
      else (unget c; uns, lng, vlng)
    in
    let uns, lng, vlng = suffix c false false false in
    let v = mpatov (Buffer.contents b) in
    let t =
      if vlng then (if uns || Int64.compare (convvtox v Tvlong) 0L < 0 then Tuvlong else Tvlong)
      else if lng then (if uns || Int64.compare (convvtox v Tlong) 0L < 0 then Tulong else Tlong)
      else if uns || Int64.compare (convvtox v Tint) 0L < 0 then Tuint else Tint
    in
    P.LCONST (convvtox v t, t)
  in
  if c <> 48 then (let c = digits c in if c = 46 || c = 101 || c = 69 then floating c else integer c)
  else begin
    add c;
    let c = getc () in
    if c = 120 || c = 88 then begin
      add c;
      let rec hex c = if is_digit c || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) then (add c; hex (getc ())) else c in
      integer (hex (getc ()))
    end
    else if c >= 48 && c <= 55 then (let rec oct c = if c >= 48 && c <= 55 then (add c; oct (getc ())) else c in integer (oct c))
    else if c = 46 || c = 101 || c = 69 then floating c
    else integer c
  end

let pairs = [ "->"; "++"; "--"; "<<"; ">>"; "<="; ">="; "=="; "!="; "&&"; "||"; "+="; "-="; "*="; "/="; "%="; "&="; "|="; "^=" ]

let rec token () : P.token =
  let c = match !peekc with Some c -> peekc := None; c | None -> raw () in
  if c = eof then P.EOF
  else if c >= 0x80 || is_alpha c || c = 95 then begin
    if c = 76 then begin
      let c1 = raw () in
      if c1 = 39 then
        (let v = match escchar 39 true with Some (c, _) -> c | None -> 39 in ignore (escchar 39 true); P.LCONST (convvtox (Int64.of_int v) Tuint, Tuint))
      else if c1 = 34 then begin
        let rec go acc = match escchar 34 true with None -> List.rev acc | Some (c, _) -> go (c :: acc) in
        (* claude: little-endian runes, as outlstring writes them *)
        P.LLSTRING (String.concat "" (List.map (fun c -> let b = Bytes.create 4 in Bytes.set_int32_le b 0 (Int32.of_int c); Bytes.to_string b) (go [])))
      end
      else (peekc := Some c1; word c)
    end
    else word c
  end
  else if is_space c then (if c = 10 then incr lineno; token ())
  else if is_digit c then number c
  else if c = 35 then (domacro (); token ())
  else if c = 34 then P.LSTRING (lexstring ())
  else if c = 39 then begin
    let v = match escchar 39 false with Some (c, _) -> c | None -> 39 in
    (match escchar 39 false with None -> () | Some _ -> error_at !lineno "missing '");
    P.LCONST (convvtox (Int64.of_int v) Tchar, Tint)
  end
  else if c = 47 then begin
    let c1 = raw () in
    if c1 = 42 then begin
      let rec skip c = if c = eof then error_at !lineno "eof in comment" else if c = 42 then (let c = getc () in if c = 47 then () else skip c) else skip (getc ()) in
      skip (getc ());
      token ()
    end
    else if c1 = 47 then (let rec eol () = let c = getc () in if c <> 10 then eol () in eol (); token ())
    else if c1 = 61 then op "/="
    else (peekc := Some c1; punct '/')
  end
  else if c = 46 then begin
    let c1 = raw () in
    if is_digit c1 then (peekc := Some c1; number_dot ())
    else if c1 = 46 then (let c2 = raw () in if c2 = 46 then op "..." else (peekc := Some c2; punct '.'))
    else (peekc := Some c1; punct '.')
  end
  else begin
    let c1 = raw () in
    let p = String.make 1 (chr c) ^ String.make 1 (if c1 >= 0 then chr c1 else ' ') in
    if (p = "<<" || p = ">>") then (let c2 = raw () in if c2 = 61 then op (p ^ "=") else (peekc := Some c2; op p))
    else if List.mem p pairs then op p
    else (peekc := Some c1; punct (chr c))
  end

(* .5: a float from its point *)
and number_dot () =
  let b = Buffer.create 16 in
  Buffer.add_char b '.';
  let rec digits c = if is_digit c then (Buffer.add_char b (chr c); digits (getc ())) else c in
  let c = digits (getc ()) in
  let c =
    if c = 101 || c = 69 then begin
      Buffer.add_char b 'e';
      let c = getc () in
      let c = if c = 43 || c = 45 then (Buffer.add_char b (chr c); getc ()) else c in
      digits c
    end
    else c
  in
  let et, c = if c = 76 || c = 108 then Tdouble, getc () else if c = 70 || c = 102 then Tfloat, getc () else Tdouble, c in
  unget c;
  P.LFCONST (float_of_string ("0" ^ Buffer.contents b), et)

and word c =
  let b = Buffer.create 16 in
  let next () = match !peekc with Some c -> peekc := None; c | None -> raw () in
  let rec go c = if is_alnum c || c = 95 || c >= 0x80 then (Buffer.add_char b (chr c); go (next ())) else c in
  let c = go c in
  peekc := Some c;
  let s = lookup (Buffer.contents b) in
  if s.macro <> None then begin
    (* the expansion is read next, then what followed *)
    let text = macexpand s in
    let text = match !peekc with Some c when c >= 0 -> peekc := None; text ^ String.make 1 (chr c) | _ -> text in
    push text;
    token ()
  end
  else if s.sclass = Ctypedef || s.sclass = Ctypestr then P.LTYPE s
  else if s.lexical > 0 then snd (List.nth keywords (s.lexical - 1)) else P.LNAME s
