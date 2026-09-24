(* The optimizer: pushing a selection down a join (chidb's optimizer.c).
 *
 * In Select(cond, NaturalJoin(Table t1, Table t2)), each conjunct of
 * cond that is a column-OP-literal comparison on one table only moves
 * next to that table; the rest stays on top. So the conjunct is checked
 * once per row of its table, not once per pair, and a pushed comparison
 * on an indexed column becomes that side's index seek (Codegen). .opt
 * shows it (checked on chidb):
 *
 *      Project([title],                        Project([title],
 *      	Select(courses.code > int 150,          	NaturalJoin(
 *      		NaturalJoin(                        		Select(courses.code > int 150,
 *      			Table(courses),                     			Table(courses)
 *      			Table(departments)                  		),
 *      		)                                   		Table(departments)
 *      	)                                       	)
 *      )                                       )
 *
 * A conjunct is on one side when it is qualified by that side's table
 * name or alias, or unqualified and a column of that side only (a name
 * in both is a join column: it stays on top). Any other statement
 * shape is left as it is.
 *
 * References: the rule is the first of relational algebra's
 * equivalences, sigma commuting with a join when it mentions one side
 * (chidb's assignment_opt page, "Pushing Sigmas", checked). *)

val optimize : Schema.item list -> Ast.t -> Ast.t
