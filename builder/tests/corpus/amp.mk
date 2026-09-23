#!setup mkdir dir; touch foo.c dir/bar.c
#!args -n foo.o
#!args -n dir/bar.o
# & matches a stem without / or .
&.o: &.c
	echo amp $stem
%.o: %.c
	echo pct $stem
