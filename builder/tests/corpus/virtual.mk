#!setup touch -d '2026-01-01 10:00:00' src; touch -d '2026-01-01 10:00:05' out
#!args -i
#!args -i all
# a virtual target is always out of date; a file depending on one
# is not, if it is newer than the virtual's prerequisites. With -i:
# without it, 9base would pretend gen was made (see pretend.mk)
all:V: out
	echo all done
out: gen
	echo making out; touch out
gen:V: src
	echo gen
