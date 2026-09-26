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
  let c = Char.code c in
  let n, v = if c land 0xe0 = 0xc0 then 1, c land 0x1f else if c land 0xf0 = 0xe0 then 2, c land 0x0f else 3, c land 0x07 in
  let rec go n v = if n = 0 then v else go (n - 1) ((v lsl 6) lor (Char.code (getc ()) land 0x3f)) in
  go n v

(* a hex digit's value, 99 if c is none *)
let hexval c =
  if is_digit c then Char.code c - 48
  else if c >= 'a' && c <= 'f' then Char.code c - 87
  else if c >= 'A' && c <= 'F' then Char.code c - 55
  else 99

let is_octal c = c >= '0' && c <= '7'

(* a character in a string or a constant, or None at its end e
 * (lex.c's escchar); an escape gives a byte, not a rune *)
let escchar e longflg =
  let c = getc () in
  if c = '\n' then error_at !lineno "newline in string";
  if c <> '\\' then (if c = e then None else Some ((if longflg && c >= '\128' then rune c else Char.code c), false))
  else
    let c = getc () in
    if c = 'x' then begin
      let rec hex i v = if i = 0 then v else let c = getc () in if hexval c < 16 then hex (i - 1) ((v * 16) + hexval c) else (unget c; v) in
      Some (hex (if longflg then 6 else 2) 0, true)
    end
    else if is_octal c then begin
      let rec oct i v = if i = 0 then v else let c = getc () in if is_octal c then oct (i - 1) ((v * 8) + hexval c) else (unget c; v) in
      Some (oct (if longflg then 8 else 2) (hexval c), true)
    end
    else Some ((match c with 'n' -> 10 | 't' -> 9 | 'b' -> 8 | 'r' -> 13 | 'f' -> 12 | 'a' -> 7 | 'v' -> 11 | c -> Char.code c), false)

(* a string's bytes: the source's UTF-8 as it is, an escape as a byte *)
let lexstring () =
  let b = Buffer.create 16 in
  let rec go () = match escchar '"' false with None -> () | Some (c, _) -> Buffer.add_char b (Char.chr (c land 255)); go () in
  go ();
  Buffer.contents b

(* lex.c's mpatov: decimal, 0 octal, 0x hex; ~0 on overflow *)
let mpatov s =
  let n = String.length s in
  let parse base start =
    let rec go i v =
      if i >= n then Some v
      else
        let d = hexval s.[i] in
        if d >= base && base <> 8 then None
        else
          let nv = Int64.add (Int64.mul v (Int64.of_int base)) (Int64.of_int d) in
          if Int64.compare v 0L < 0 && Int64.compare nv 0L >= 0 then None else go (i + 1) nv
    in
    go start 0L
  in
  let r = if n > 1 && s.[0] = '0' then (if s.[1] = 'x' || s.[1] = 'X' then parse 16 2 else parse 8 1) else parse 10 0 in
  match r with Some v -> v | None -> -1L

(* a number, from its first digit or its point *)
let number c =
  let b = Buffer.create 16 in
  let add = Buffer.add_char b in
  let rec digits c = if is_digit c then (add c; digits (getc ())) else c in
  let exponent c = c = 'e' || c = 'E' in
  let floating c =
    (* the fraction and the exponent (casedot, casee) *)
    let c = if c = '.' then (add c; digits (getc ())) else c in
    let c = if exponent c then (add 'e'; let c = getc () in digits (if c = '+' || c = '-' then (add c; getc ()) else c)) else c in
    let et, c = if c = 'L' || c = 'l' then Tdouble, getc () else if c = 'F' || c = 'f' then Tfloat, getc () else Tdouble, c in
    unget c;
    P.LFCONST (float_of_string (Buffer.contents b), et)
  and integer c =
    let rec suffix c uns lng vlng =
      if (c = 'U' || c = 'u') && not uns then suffix (getc ()) true lng vlng
      else if (c = 'L' || c = 'l') && not vlng then suffix (getc ()) uns true lng
      else (unget c; uns, lng, vlng)
    in
    let uns, lng, vlng = suffix c false false false in
    let v = mpatov (Buffer.contents b) in
    let neg t = Int64.compare (convvtox v t) 0L < 0 in
    let t =
      if vlng then (if uns || neg Tvlong then Tuvlong else Tvlong)
      else if lng then (if uns || neg Tlong then Tulong else Tlong)
      else if uns || neg Tint then Tuint else Tint
    in
    P.LCONST (convvtox v t, t)
  in
  if c <> '0' then (let c = digits c in if c = '.' || exponent c then floating c else integer c)
  else begin
    add c;
    let c = getc () in
    if c = 'x' || c = 'X' then (add c; let rec hex c = if hexval c < 16 then (add c; hex (getc ())) else c in integer (hex (getc ())))
    else if is_octal c then (let rec oct c = if is_octal c then (add c; oct (getc ())) else c in integer (oct c))
    else if c = '.' || exponent c then floating c
    else integer c
  end

let pairs = [ "->"; "++"; "--"; "<<"; ">>"; "<="; ">="; "=="; "!="; "&&"; "||"; "+="; "-="; "*="; "/="; "%="; "&="; "|="; "^=" ]

(* a character constant's value: its first character, ' if none *)
let charconst longflg = match escchar '\'' longflg with Some (c, _) -> c | None -> 39

let rec token () : P.token =
  let c = read () in
  if c = eof then P.EOF
  else if c >= '\128' || is_alpha c || c = '_' then begin
    if c = 'L' then begin
      let c1 = raw () in
      if c1 = '\'' then (let v = charconst true in ignore (escchar '\'' true); P.LCONST (convvtox (Int64.of_int v) Tuint, Tuint))
      else if c1 = '"' then begin
        let rec go acc = match escchar '"' true with None -> List.rev acc | Some (c, _) -> go (c :: acc) in
        (* claude: little-endian runes, as outlstring writes them *)
        P.LLSTRING (String.concat "" (List.map (fun c -> let b = Bytes.create 4 in Bytes.set_int32_le b 0 (Int32.of_int c); Bytes.to_string b) (go [])))
      end
      else (peekc := Some c1; word c)
    end
    else word c
  end
  else if is_space c then (if c = '\n' then incr lineno; token ())
  else if is_digit c then number c
  else if c = '#' then (domacro (); token ())
  else if c = '"' then P.LSTRING (lexstring ())
  else if c = '\'' then begin
    let v = charconst false in
    (match escchar '\'' false with None -> () | Some _ -> error_at !lineno "missing '");
    P.LCONST (convvtox (Int64.of_int v) Tchar, Tint)
  end
  else if c = '/' then begin
    let c1 = raw () in
    if c1 = '*' then begin
      let rec skip c = if c = eof then error_at !lineno "eof in comment" else if c = '*' then (let c = getc () in if c = '/' then () else skip c) else skip (getc ()) in
      skip (getc ());
      token ()
    end
    else if c1 = '/' then (let rec eol () = if getc () <> '\n' then eol () in eol (); token ())
    else if c1 = '=' then op "/="
    else (peekc := Some c1; punct '/')
  end
  else if c = '.' then begin
    let c1 = raw () in
    if is_digit c1 then (peekc := Some c1; number c)
    else if c1 = '.' then (let c2 = raw () in if c2 = '.' then op "..." else (peekc := Some c2; punct '.'))
    else (peekc := Some c1; punct '.')
  end
  else begin
    let c1 = raw () in
    let p = String.make 1 c ^ String.make 1 (if c1 <> eof then c1 else ' ') in
    if p = "<<" || p = ">>" then (let c2 = raw () in if c2 = '=' then op (p ^ "=") else (peekc := Some c2; op p))
    else if List.mem p pairs then op p
    else (peekc := Some c1; punct c)
  end

and word c =
  let b = Buffer.create 16 in
  let rec go c = if is_alnum c || c = '_' || c >= '\128' then (Buffer.add_char b c; go (read ())) else c in
  peekc := Some (go c);
  let s = lookup (Buffer.contents b) in
  if s.macro <> None then begin
    (* the expansion is read next, then what followed *)
    let text = macexpand s in
    let text = match !peekc with Some c when c <> eof -> peekc := None; text ^ String.make 1 c | _ -> text in
    push text;
    token ()
  end
  else if s.sclass = Ctypedef || s.sclass = Ctypestr then P.LTYPE s
  else if s.lexical > 0 then snd (List.nth keywords (s.lexical - 1)) else P.LNAME s
