# The usual entry points; dune does the work.

all:
	dune build

test: all
	./_build/default/builder/tests/Test.exe

# The same corpus through plan9port (9base) mk and xix's omk too, when
# they are installed; see builder/tests/differential.sh.
test-differential: all
	./builder/tests/differential.sh

clean:
	dune clean

.PHONY: all test test-differential clean
