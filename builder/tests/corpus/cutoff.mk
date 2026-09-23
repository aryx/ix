#!setup echo v1 > config.in; cp config.in config.h; touch -d '2026-01-01 10:00:00' config.h; touch -d '2026-01-01 10:00:05' foo.o; touch -d '2026-01-01 10:00:10' config.in
#!args foo.o
# early cutoff: config.h is regenerated identically, foo.o is not rebuilt
foo.o: config.h
	echo compile foo.o; touch foo.o
config.h: config.in
	cp config.in config.h.new
	cmp -s config.h.new config.h || mv config.h.new config.h
	rm -f config.h.new
