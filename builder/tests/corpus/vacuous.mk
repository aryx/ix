#!setup touch hello.c
#!args -n hello.5
#!args -n both.5
#!setup touch both.c both.s
#!args -n both.5
# a metarule whose prerequisite can't be made is dropped
%.5: %.c
	echo 5c $stem.c
%.5: %.s
	echo 5a $stem.s
