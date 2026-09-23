#!setup touch -d '2026-01-01 10:00:00' foo.c foo.o
#!args
# equal times count as out of date
foo.o: foo.c
	echo compile
