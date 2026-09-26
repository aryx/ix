(* The arithmetic rewrites (scon.c's acom), 5c's and not the language's:
 * a sum's terms busted out, sorted, factored and put back together, so
 * that 4+8*a+16*b+5 is 9+8*(a+2*b), as arises "from address
 * manipulation and array indexing" (Ken Thompson, "Plan 9 C
 * Compilers", section "Arithmetic rewrites"). The terms are sorted as
 * 5c's qsort does on glibc (a merge sort), so equal terms keep 5c's
 * order: the listing depends on it.
 *
 * A pass of the front end's in 5c (Check.complex's, after ccom), a
 * pass of this back end's here: compat's xcom hook runs it first. *)

val acom : Tree.expr -> Tree.expr
