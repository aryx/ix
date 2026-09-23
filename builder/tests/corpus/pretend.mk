#!setup touch -d '2026-01-01 10:00:00' src; touch -d '2026-01-01 10:00:05' out
#!args
# 9base pretends a missing intermediate is made when its parent is up to
# date with the intermediate's prerequisites; principia's mk does not
# (-i by default), nor TinyMk: this case records the difference
out: gen
	echo making out; touch out
gen:V: src
	echo gen
