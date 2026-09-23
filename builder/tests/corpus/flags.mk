#!setup touch -d '2026-01-01 10:00:00' a.c b.c; touch -d '2026-01-01 10:00:05' a.o b.o; touch -d '2026-01-01 10:00:10' prog
#!args
#!args -a -n
#!args -n -w a.c
#!args -t
#!args
# -a, -w, -t
prog: a.o b.o
	echo link
%.o: %.c
	echo cc $stem
