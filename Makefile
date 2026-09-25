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
	./tiny/TinyArm_test.sh
	./tiny/TinyCPU_test.sh
	./tiny/TinyMachine_test.sh
	./machine/tests/decode_check.py
	./machine/tests/decode_check.py --random 5000
	./machine/tests/decode_check.py -64
	./machine/tests/decode_check.py -64 --random 5000
	./machine/tests/decode_check.py -64 machine/tests/words_arm64_system.txt
	./machine/tests/random_blocks.py 3000 30
	./machine/tests/random_blocks.py -64 3000 30

# The same corpus through plan9port (9base) mk and xix's omk too, when
# they are installed; see builder/tests/differential.sh.
test-differential: all
	./builder/tests/differential.sh live

# The toolchain against goken (~/goken, built, with its libcs): C
# programs with its libc, byte for byte and run; see linker/tests/
# (golden.sh record re-records the fixtures' bytes from goken). The
# compiler's listings against 5c -O0's and 7c -O0's, on the corpus, on
# compiler/tests/c/ and on random programs; see compiler/tests/ (and
# MINICC=1 linker/tests/libc.sh for the executables mini-cc and mini-ld
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
	./machine/tests/corpus.py 5 $(GOKEN_W)/libc5/*/*.exe
	./machine/tests/corpus.py 7 $(GOKEN_W)/libc7/*/*.exe
	GOOS=plan9 H=-H2 ./linker/tests/libc.sh 5 $(GOKEN_W)/plan9_5 $(HOME)/goken/tests/c/hello_libc/*.c
	./machine/tests/plan9.py $(GOKEN_W)/plan9_5 $(GOKEN_W)/libc5

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

.PHONY: all test test-differential test-goken test-chidb test-pi clean build-docker build-docker-ocaml5

# mini-qemu against QEMU (plan_pi.md): 9pi's session, the xv6 Pi
# ports' boots (the Pi1's and the Pi4's), the Pi1's graphics; needs
# ~/principia, ~/xv6 and the QEMUs (see raspberry/tests/). With
# XV6_USERTESTS=-u, each xv6 port's usertests too (the Pi4's: hours).
test-pi: all
	dune build --profile release ./raspberry/Main.exe
	./raspberry/tests/9pi.py
	./raspberry/tests/xv6.sh $(XV6_USERTESTS)
	./raspberry/tests/graphics.py

# mini-git over the Internet: ix cloned from GitHub by mini-git (https,
# through curl), checked by git fsck and walk.
test-github: all
	rm -rf /tmp/ix-github && ./_build/default/version_control/Main.exe clone https://github.com/aryx/ix /tmp/ix-github
	git --git-dir=/tmp/ix-github/.git fsck --strict
	cd /tmp/ix-github && $(CURDIR)/_build/default/version_control/Main.exe walk -q
