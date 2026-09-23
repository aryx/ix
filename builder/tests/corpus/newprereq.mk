#!setup touch -d '2026-01-01 10:00:00' a b; touch -d '2026-01-01 10:00:05' t; touch -d '2026-01-01 10:00:10' b
#!args
# $newprereq: the prerequisites newer than the target
t: a b
	echo prereq=$prereq newprereq=$newprereq
