#!setup touch -d '2026-01-01 10:00:00.2' foo.c; touch -d '2026-01-01 10:00:00.7' foo.o
#!args
# foo.o is half a second newer than foo.c: 9base sees whole seconds,
# equal times, and rebuilds; TinyMk sees sub-second times (subsecond.tiny.out)
foo.o: foo.c
	echo compile
