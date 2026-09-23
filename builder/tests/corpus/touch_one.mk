#!setup touch -d '2026-01-01 10:00:00' hello.c world.c; touch -d '2026-01-01 10:00:10' hello.5 world.5; touch -d '2026-01-01 10:00:20' hello; touch -d '2026-01-01 10:00:30' world.c
#!args
#!setup touch -d '2026-01-01 11:00:00' *.5; touch -d '2026-01-01 11:00:10' hello
#!args
# touching one leaf rebuilds exactly what depends on it
hello: hello.5 world.5
	echo link; touch hello
%.5: %.c
	echo compile $stem; touch $target
