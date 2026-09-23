#!setup touch -d '2026-01-01 10:00:00' y.y
#!args -n
#!args
#!setup touch -d '2026-01-01 11:00:00' y.tab.c y.tab.h; touch -d '2026-01-01 11:00:10' prog
#!args
# one recipe makes both targets: one job, $target both, $alltarget
prog: y.tab.c y.tab.h
	echo cc $prereq; touch prog
y.tab.c y.tab.h: y.y
	echo yacc $target all=$alltarget; touch $target
