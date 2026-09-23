#!args -n a
#!args -n b
# :N: no recipe needed; :n: not after a virtual rule
a: x
x:N:
b: y
y:V:
	echo virtual y
%:n:
	echo meta $target
