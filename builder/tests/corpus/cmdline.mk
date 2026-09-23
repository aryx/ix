#!args -n a b
#!args -n -s a b
#!args -n c
#!args -n X=1 flags
# several targets: one virtual rule for them, or -s one after the other
a:V: c
	echo a
b:V: c
	echo b
c:V:
	echo c
flags:V:
	echo MKFLAGS=$MKFLAGS MKARGS=$MKARGS
