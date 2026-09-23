#!setup touch foo.gz.gz
#!args -n foo
#!args -n NREP=2 foo
# NREP: how often a metarule repeats on a path
%: %.gz
	echo gunzip $stem.gz
