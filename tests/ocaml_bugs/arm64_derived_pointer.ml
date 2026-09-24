(* claude: a minimal reproduction. [go] reads b.[pos] in its test and again
 * after allocating the list cell; the second read reuses the address
 * computed for the first, which a minor GC may have made stale. *)
let rec go b pos acc =
  if pos >= Bytes.length b then acc
  else if Char.code (Bytes.get b pos) land 0x80 <> 0 then go b (pos + 1) (1000 :: acc)
  else go b (pos + 1) (Char.code (Bytes.get b pos) :: acc)

let () =
  let b = Bytes.of_string "\001\002\003\004\005\006\007\008" in
  let expected = go b 0 [] in
  let bad = ref 0 in
  for i = 1 to 1_000_000 do
    if go (Bytes.copy b) 0 [] <> expected then incr bad;
    if i mod 100 = 0 then ignore (Array.make 300 0)
  done;
  Printf.printf "bad: %d\n" !bad
