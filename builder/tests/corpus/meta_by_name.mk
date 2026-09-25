#!args -n %.o
#!args -n hello.o
# a metarule's target text names no file: mk '%.o' finds no rule
# (mini-mk crashed there, a metarule taken for an exact one)
%.o: %.c
	echo compile $stem
hello.c:V:
	echo source
