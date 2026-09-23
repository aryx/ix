#!setup echo a > a.c; echo b > b.c; touch -d '2026-01-01 10:00:00' a.c b.c
#!args
#!args
#!setup touch -d '2026-01-01 11:00:00' lib.a; touch -d '2026-01-01 12:00:00' b.c
#!args
#!args -n
# a library rebuilt one member at a time (mklib's pattern, with GNU ar:
# U keeps real dates in the headers, which Debian's ar zeroes otherwise)
LIB=lib.a
OFILES=a.o b.o
$LIB: ${OFILES:%=$LIB(%)}
	ar rcU $LIB $newmember 2>/dev/null; echo members $newmember
$LIB(%.o):N: %.o
%.o: %.c
	cp $stem.c $stem.o; touch -r $stem.c $stem.o; echo cc $stem
