#!args -n a
#!args -n b
# two recipes for one target; a simple rule beats a metarule
a:V: x
	echo one
a:V: y
	echo two
b.o:V:
	echo simple b.o
%.o:V:
	echo meta $target
x y:V:
	echo $target
