#!setup echo same > a; echo same > b; echo other > c
#!args ab
#!args ac
# :P: a command decides, not the times
ab:VPcmp -s: a b
	echo ab out of date
ac:VPcmp -s: a c
	echo ac out of date
