# The usual entry points; dune does the work.

all:
	dune build

test: all
	./_build/default/builder/tests/Test.exe
	./tiny/TinyBuildSystem_test.sh
	./_build/default/shell/tests/Test.exe
	./tiny/TinyShell_test.sh
	./_build/default/editor/tests/Test.exe
	./tiny/TinyEditor_test.sh

# The same corpus through plan9port (9base) mk and xix's omk too, when
# they are installed; see builder/tests/differential.sh.
test-differential: all
	./builder/tests/differential.sh live

clean:
	dune clean

.PHONY: all test test-differential clean
