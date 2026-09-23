#!args -n a
a: b
	echo a
b: c
	echo b
c: a
	echo c
