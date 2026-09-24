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
	./_build/default/database/tests/Test.exe
	./tiny/TinyDatabase_test.sh 20
	./lib_compression/tests/check.py 50
	./version_control/tests/objects.sh
	./version_control/tests/query.py 10
	./version_control/tests/session.py 10
	./version_control/tests/git9_tests.sh
	./version_control/tests/net.sh
	./tiny/TinyVCS_test.sh 10

# The same corpus through plan9port (9base) mk and xix's omk too, when
# they are installed; see builder/tests/differential.sh.
test-differential: all
	./builder/tests/differential.sh live

# The toolchain against goken (~/goken, built, with its libcs): C
# programs with its libc, byte for byte and run; see linker/tests/
# (golden.sh record re-records the fixtures' bytes from goken). The
# compiler's listings against 5c -O0's and 7c -O0's, on the corpus, on
# compiler/tests/c/ and on random programs; see compiler/tests/ (and
# TINYCC=1 linker/tests/libc.sh for the executables tinycc and tinyld
# make).
GOKEN_W = /tmp/ix-goken
test-goken: all
	./linker/tests/libc.sh 5 $(GOKEN_W)/libc5 $(HOME)/goken/tests/c/hello_libc/*.c
	./linker/tests/libc.sh 7 $(GOKEN_W)/libc7 $(HOME)/goken/tests/c/hello_libc/*.c
	./tiny/TinyAssembler_test.sh
	./tiny/TinyC_test.sh
	./compiler/tests/listing.sh 5 $(GOKEN_W)/listing5 $(HOME)/goken/tests/c/hello_libc/*.c compiler/tests/c/*.c
	./compiler/tests/listing.sh 7 $(GOKEN_W)/listing7 $(HOME)/goken/tests/c/hello_libc/*.c compiler/tests/c/*.c
	./compiler/tests/fuzz.sh $(GOKEN_W)/fuzz 150
	P9DIFF=$(GOKEN_W)/p9diff ./version_control/tests/diff_fuzz.py 500

# The database against chidb (~/github/chidb, built): the course's
# .dbmf cases (in make test too, when chidb's checkout is there), the
# SQL corpus (stdout, stderr, the file, and SQLite reading it), the
# B-trees alone, and random sessions; see database/tests/.
test-chidb: all
	./_build/default/database/tests/Test.exe
	./database/tests/differential.sh
	./database/tests/btree_differential.sh
	./database/tests/fuzz.py 1 40

clean:
	dune clean

# Build and test in a fresh Ubuntu, as GitHub Actions does
# (.github/workflows/docker.yml).
build-docker:
	docker build -t "ix" .

build-docker-ocaml5:
	docker build -t "ix" --build-arg OCAML_VERSION=5.1.1 .

.PHONY: all test test-differential test-goken test-chidb clean build-docker build-docker-ocaml5
