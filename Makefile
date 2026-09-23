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
	./linker/tests/golden.sh

# The same corpus through plan9port (9base) mk and xix's omk too, when
# they are installed; see builder/tests/differential.sh.
test-differential: all
	./builder/tests/differential.sh live

# The toolchain against goken (~/goken, built, with its libcs): C
# programs with its libc, byte for byte and run; see linker/tests/
# (golden.sh record re-records the fixtures' bytes from goken). The
# compiler's trees against cck's, and its listings against 5c -O0's and
# 7c -O0's; see compiler/tests/ (and TINYCC=1 linker/tests/libc.sh for
# the executables tinycc and tinyld make).
GOKEN_W = /tmp/ix-goken
test-goken: all
	./linker/tests/libc.sh 5 $(GOKEN_W)/libc5 $(HOME)/goken/tests/c/hello_libc/*.c
	./linker/tests/libc.sh 7 $(GOKEN_W)/libc7 $(HOME)/goken/tests/c/hello_libc/*.c
	./tiny/TinyAssembler_test.sh
	./compiler/tests/front.sh 5 $(GOKEN_W)/front5 $(HOME)/goken/tests/c/hello_libc/*.c
	./compiler/tests/front.sh 7 $(GOKEN_W)/front7 $(HOME)/goken/tests/c/hello_libc/*.c
	./compiler/tests/listing.sh 5 $(GOKEN_W)/listing5 $(HOME)/goken/tests/c/hello_libc/*.c
	./compiler/tests/listing.sh 7 $(GOKEN_W)/listing7 $(HOME)/goken/tests/c/hello_libc/*.c

clean:
	dune clean

.PHONY: all test test-differential test-goken clean
