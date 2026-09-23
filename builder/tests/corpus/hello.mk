#!setup touch -d '2026-01-01 10:00:00' hello.c world.c
#!args -n
#!args
#!setup touch -d '2026-01-01 11:00:00' *.5; touch -d '2026-01-01 11:00:10' hello
#!args
#!args -n clean
# principia's SRC/cmd/mk/tests/hello.mk, the compilers faked
OBJS=hello.5 world.5

hello: $OBJS
	echo 5l -o hello $OBJS; touch hello

%.5: %.c
	echo 5c -c $stem.c; touch $stem.5

clean:V:
	rm -f *.5 hello
