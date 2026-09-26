#!/usr/bin/env python3
# Claude Code
#
# Copyright (C) 2026 Yoann Padioleau
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Library General Public License
# (LGPL) as published by the Free Software Foundation; either version
# 2 of the License, or (at your option) any later version.
#
# Random ML programs for TinyML_test.sh: well typed by construction
# (each expression generated for a type, from the variables of that
# type in scope, as Palka et al.'s generator for GHC, 2011), in the
# subset tiny-ml and ocaml-light share: integers, booleans, lists,
# pairs, a variant, closures and partial applications, let rec loops
# (bounded), exceptions, references, and prints inside expressions, so
# that the order of evaluation shows. Every loop is bounded and no
# recursion is unbounded, so each program ends; its toplevel values are
# printed. RECORD=1 TinyML_test.sh dir/*.ml then compares tiny-ml with
# ocamlopt on them.
#
# usage: TinyML_fuzz.py dir count [seed]

import random
import sys

INT, BOOL, LIST, FUN, PAIR, T = 'int', 'bool', 'int list', 'int -> int', 'int * int', 't'

HEADER = """type t = A | B of int | C of int * int
exception E of int
let rec pl = function [] -> print_newline () | x :: l -> print_int x; print_char ' '; pl l
let pt = function A -> print_string "A\\n" | B n -> print_int n; print_newline () | C (a, b) -> print_int (a - b); print_newline ()
"""


class Gen:
    def __init__(self, rnd):
        self.r = rnd
        self.n = 0

    def fresh(self, p='v'):
        self.n += 1
        return '%s%d' % (p, self.n)

    def pick(self, env, ty):
        return [x for x, t in env if t == ty]

    def small(self):
        return str(self.r.choice([0, 1, 2, 3, 5, 7, 10, 100, 12345, 4611686018427387903]))

    def int_lit(self):
        s = self.small()
        return '(-%s)' % s if self.r.random() < 0.2 else s

    def gen(self, ty, env, d):
        """an expression of type ty; d the depth left"""
        vs = self.pick(env, ty)
        if d <= 0 or self.r.random() < 0.15:
            if vs and self.r.random() < 0.7:
                return self.r.choice(vs)
            return self.leaf(ty, env)
        return getattr(self, 'gen_' + {INT: 'int', BOOL: 'bool', LIST: 'list', FUN: 'fun', PAIR: 'pair', T: 't'}[ty])(env, d - 1)

    def leaf(self, ty, env):
        if ty == INT:
            return self.int_lit()
        if ty == BOOL:
            return self.r.choice(['true', 'false'])
        if ty == LIST:
            return self.r.choice(['[]', '[%s]' % self.int_lit(), '[1; 2; 3]'])
        if ty == FUN:
            return self.r.choice(['(fun x -> x)', '(fun x -> x + 1)', 'succ', '(( * ) 2)'])
        if ty == PAIR:
            return '(%s, %s)' % (self.int_lit(), self.int_lit())
        return self.r.choice(['A', '(B 4)', '(C (1, 2))'])

    def let(self, ty, env, d):
        t2 = self.r.choice([INT, INT, LIST, FUN, PAIR, T])
        x = self.fresh()
        return '(let %s = %s in %s)' % (x, self.gen(t2, env, d), self.gen(ty, env + [(x, t2)], d))

    def gen_int(self, env, d):
        g = lambda t: self.gen(t, env, d)
        c = self.r.randrange(17)
        if c == 0:
            return '(%s %s %s)' % (g(INT), self.r.choice(['+', '-', '*', '/', 'mod', 'land', 'lor', 'lxor']), g(INT))
        if c == 1:
            return '(%s %s (%s land 7))' % (g(INT), self.r.choice(['lsl', 'lsr', 'asr']), g(INT))
        if c == 2:
            return '(if %s then %s else %s)' % (g(BOOL), g(INT), g(INT))
        if c == 3:
            return self.let(INT, env, d)
        if c == 4:
            # the function named first: ocaml-light's ocamlopt evaluates the
            # let of (let v = e in fun x -> ..) a twice (plan_ml.md's Status)
            f = self.fresh('f')
            return '(let %s = %s in %s %s)' % (f, g(FUN), f, g(INT))
        if c == 5:
            x, r = self.fresh('x'), self.fresh('r')
            return '(match %s with [] -> %s | %s :: %s -> %s)' % (g(LIST), g(INT), x, r, self.gen(INT, env + [(x, INT), (r, LIST)], d))
        if c == 6:
            return '(List.length %s)' % g(LIST)
        if c == 7:
            return '(List.fold_left (fun a b -> a %s b) %s %s)' % (self.r.choice(['+', '-', 'lxor']), g(INT), g(LIST))
        if c == 8:
            return '(%s %s)' % (self.r.choice(['fst', 'snd']), g(PAIR))
        if c == 9:
            # the order of evaluation shows
            return '(print_int %s; print_char %s; %s)' % (g(INT), self.r.choice(["' '", "','"]), g(INT))
        if c == 10:
            x = self.fresh('x')
            return '(try (if %s then raise (E %s) else %s) with E %s -> %s)' % (g(BOOL), g(INT), g(INT), x, self.gen(INT, env + [(x, INT)], d))
        if c == 11:
            a, b, x, y = self.fresh('a'), self.fresh('b'), self.fresh('x'), self.fresh('y')
            e = [(a, INT), (x, INT), (y, INT)]
            return '(match %s with A -> %s | B %s -> %s | C (%s, %s) -> %s)' % (
                g(T), g(INT), a, self.gen(INT, env + e[:1], d), x, y, self.gen(INT, env + e[1:], d))
        if c == 12:
            # a bounded loop, in tail position
            f, i, acc = self.fresh('loop'), self.fresh('i'), self.fresh('acc')
            body = self.gen(INT, env + [(i, INT), (acc, INT)], d)
            return '(let rec %s %s %s = if %s <= 0 then %s else %s (%s - 1) (%s + %s) in %s %d 0)' % (
                f, i, acc, i, acc, f, i, acc, body, f, self.r.randrange(0, 50))
        if c == 13:
            r = self.fresh('r')
            return '(let %s = ref %s in %s := !%s + %s; !%s)' % (r, g(INT), r, r, g(INT), r)
        if c == 14:
            # a function of two arguments, applied through an unknown call
            f, x, y = self.fresh('f'), self.fresh('x'), self.fresh('y')
            body = self.gen(INT, env + [(x, INT), (y, INT)], d)
            return '(let %s %s %s = %s in let g = %s %s in g %s)' % (f, x, y, body, f, g(INT), g(INT))
        if c == 15:
            return '(compare %s %s)' % self.two(env, d)
        return self.let(INT, env, d)

    def two(self, env, d):
        t = self.r.choice([INT, LIST, PAIR, T])
        return self.gen(t, env, d), self.gen(t, env, d)

    def gen_bool(self, env, d):
        g = lambda t: self.gen(t, env, d)
        c = self.r.randrange(5)
        if c == 0:
            return '(%s %s %s)' % (g(INT), self.r.choice(['<', '<=', '>', '>=', '=', '<>']), g(INT))
        if c == 1:
            return '(not %s)' % g(BOOL)
        if c == 2:
            return '(%s %s %s)' % (g(BOOL), self.r.choice(['&&', '||']), g(BOOL))
        if c == 3:
            a, b = self.two(env, d)
            return '(%s %s %s)' % (a, self.r.choice(['=', '<>', '<', '>=']), b)
        return '(List.mem %s %s)' % (g(INT), g(LIST))

    def gen_list(self, env, d):
        g = lambda t: self.gen(t, env, d)
        c = self.r.randrange(7)
        if c == 0:
            return '(%s :: %s)' % (g(INT), g(LIST))
        if c == 1:
            return '(List.map %s %s)' % (g(FUN), g(LIST))
        if c == 2:
            return '(List.rev %s)' % g(LIST)
        if c == 3:
            return '(%s @ %s)' % (g(LIST), g(LIST))
        if c == 4:
            x = self.fresh('x')
            return '(List.filter (fun %s -> %s) %s)' % (x, self.gen(BOOL, env + [(x, INT)], d), g(LIST))
        if c == 5:
            return '[%s; %s]' % (g(INT), g(INT))
        return self.let(LIST, env, d)

    def gen_fun(self, env, d):
        c = self.r.randrange(4)
        if c == 0:
            x = self.fresh('x')
            return '(fun %s -> %s)' % (x, self.gen(INT, env + [(x, INT)], d))
        if c == 1:
            x, y = self.fresh('x'), self.fresh('y')
            return '((fun %s %s -> %s) %s)' % (x, y, self.gen(INT, env + [(x, INT), (y, INT)], d), self.gen(INT, env, d))
        if c == 2:
            f, g, x = self.fresh('f'), self.fresh('f'), self.fresh('x')
            return '(let %s = %s in let %s = %s in fun %s -> %s (%s %s))' % (f, self.gen(FUN, env, d), g, self.gen(FUN, env, d), x, f, g, x)
        return self.let(FUN, env, d)

    def gen_pair(self, env, d):
        if self.r.random() < 0.8:
            return '(%s, %s)' % (self.gen(INT, env, d), self.gen(INT, env, d))
        return self.let(PAIR, env, d)

    def gen_t(self, env, d):
        c = self.r.randrange(3)
        if c == 0:
            return 'A'
        if c == 1:
            return '(B %s)' % self.gen(INT, env, d)
        return '(C (%s, %s))' % (self.gen(INT, env, d), self.gen(INT, env, d))

    def program(self):
        out, env = [HEADER], []
        for _ in range(self.r.randrange(3, 8)):
            ty = self.r.choice([INT, INT, LIST, FUN, PAIR, T])
            x = self.fresh('g')
            if ty == FUN and self.r.random() < 0.5:
                y = self.fresh('y')
                out.append('let %s %s = %s' % (x, y, self.gen(INT, env + [(y, INT)], 4)))
            else:
                out.append('let %s = %s' % (x, self.gen(ty, env, 4)))
            env.append((x, ty))
            out.append({INT: 'let () = print_int %s; print_newline ()', LIST: 'let () = pl %s',
                        FUN: 'let () = print_int (%s 3); print_newline ()', PAIR: 'let () = print_int (fst %s); print_newline ()',
                        T: 'let () = pt %s'}[ty] % x)
        return '\n'.join(out) + '\n'


def main():
    if len(sys.argv) < 3:
        sys.exit('usage: TinyML_fuzz.py dir count [seed]')
    d, n = sys.argv[1], int(sys.argv[2])
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    for i in range(n):
        with open('%s/r%03d.ml' % (d, i), 'w') as f:
            f.write(Gen(random.Random(seed * 100003 + i)).program())


main()
