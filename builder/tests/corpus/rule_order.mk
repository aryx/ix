#!args -n a
# several rules for one target: the first, then the newest first
a:V: b
a:V: c
a:V: d
	echo a from $prereq
b c d e f:V:
	echo making $target
