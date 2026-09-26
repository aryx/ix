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
	./tiny/TinyCPUArm_test.sh
	./tiny/TinyMachinePi_test.sh
	./tiny/TinyCPU_test.sh
	./tiny/TinyMachine_test.sh
	$(MAKE) -C tiny/tiny-os clean all
	$(MAKE) -C tiny/tiny-os/v6 check
	$(MAKE) -C tiny/tiny-os/t6 check
	./machine/tests/decode_check.py
	./machine/tests/decode_check.py --random 5000
	./machine/tests/decode_check.py -64
	./machine/tests/decode_check.py -64 --random 5000
	./machine/tests/decode_check.py -64fp --random 5000
	./machine/tests/decode_check.py machine/tests/words_arm_system.txt
	./machine/tests/decode_check.py -64 machine/tests/words_arm64_system.txt
	./machine/tests/random_blocks.py 3000 30
	./machine/tests/random_blocks.py -64 3000 30
	./machine/tests/random_blocks.py -vfp 1000 30
	./machine/tests/random_blocks.py -64fp 1000 30

# The same corpus through plan9port (9base) mk and xix's omk too, when
# they are installed; see builder/tests/differential.sh.
test-differential: all
	./builder/tests/differential.sh live

# The toolchain against goken (~/goken, built, with its libcs): C
# programs with its libc, byte for byte and run; see linker/tests/
# (golden.sh record re-records the fixtures' bytes from goken). The
# compiler's listings against 5c -O0's and 7c -O0's, on the corpus, on
# languages/c/tests/c/ and on random programs; see languages/c/tests/ (and
# MINICC=1 linker/tests/libc.sh for the executables mini-cc and mini-ld
# make).
GOKEN_W = /tmp/ix-goken
test-goken: all
	./linker/tests/libc.sh 5 $(GOKEN_W)/libc5 $(HOME)/goken/tests/c/hello_libc/*.c
	./linker/tests/libc.sh 7 $(GOKEN_W)/libc7 $(HOME)/goken/tests/c/hello_libc/*.c
	./tiny/TinyAssembler_test.sh
	./tiny/TinyC_test.sh
	./tiny/TinyML_test.sh
	mkdir -p $(GOKEN_W)/tinyc32 && ./tiny/TinyC_fuzz.py --32 $(GOKEN_W)/tinyc32 100 && ./tiny/TinyC_test.sh $(GOKEN_W)/tinyc32/*.c
	./languages/c/tests/listing.sh 5 $(GOKEN_W)/listing5 $(HOME)/goken/tests/c/hello_libc/*.c languages/c/tests/c/*.c
	./languages/c/tests/listing.sh 7 $(GOKEN_W)/listing7 $(HOME)/goken/tests/c/hello_libc/*.c languages/c/tests/c/*.c
	./languages/c/tests/fuzz.sh $(GOKEN_W)/fuzz 150
	P9DIFF=$(GOKEN_W)/p9diff ./version_control/tests/diff_fuzz.py 500
	./machine/tests/corpus.py 5 $(GOKEN_W)/libc5/*/*.exe
	./machine/tests/corpus.py 7 $(GOKEN_W)/libc7/*/*.exe
	GOOS=plan9 H=-H2 ./linker/tests/libc.sh 5 $(GOKEN_W)/plan9_5 $(HOME)/goken/tests/c/hello_libc/*.c
	./machine/tests/plan9.py $(GOKEN_W)/plan9_5 $(GOKEN_W)/libc5

# The ML compilers against ocaml-light's ocamlopt for arm64 and arm
# (kernel/ocaml-light.sh arm64 and arm build them in
# /tmp/ix-ocaml-light-*), and goken: tiny-ml on random programs, their
# outputs recorded by ocamlopt, then compared (make test-goken compares
# the recorded ones; see tiny/TinyML_fuzz.py); mini-ml's front end and
# type checker over the corpus (languages/ml/tests/), its programs
# (tests/tiny/, ocaml-light's test/, the random ones), on arm64 and, under
# qemu-arm, on arm, run and compared with ocamlopt's.
OCAML_LIGHT_TESTS = $(addprefix $(HOME)/ocaml-light/test/,fib.ml takc.ml taku.ml sieve.ml quicksort.ml soli.ml bdd.ml boyer.ml nucleic.ml KB Moretest/bigints.ml Moretest/equality.ml Moretest/io.ml Moretest/patmatch.ml Moretest/signals.ml Moretest/wc.ml Moretest/testrandom.ml)
test-ocaml: all
	mkdir -p $(GOKEN_W)/tinyml && ./tiny/TinyML_fuzz.py $(GOKEN_W)/tinyml 100 && RECORD=1 ./tiny/TinyML_test.sh $(GOKEN_W)/tinyml/*.ml
	./languages/ml/tests/corpus.sh
	./languages/ml/tests/types.sh
	./languages/ml/tests/run.sh 7 $(GOKEN_W)/ml7 languages/ml/tests/tiny/*.ml
	LIVE=1 ./languages/ml/tests/run.sh 7 $(GOKEN_W)/ml7 $(OCAML_LIGHT_TESTS)
	LIVE=1 ./languages/ml/tests/run.sh 5 $(GOKEN_W)/ml5 $(addprefix languages/ml/tests/tiny/,arith.ml closures.ml compare.ml exceptions.ml gc.ml lists.ml loops.ml strings.ml variants.ml)
	LIVE=1 ./languages/ml/tests/run.sh 7 $(GOKEN_W)/ml7 $(GOKEN_W)/tinyml/*.ml

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

# Lines of OCaml, per mini program, tiny program and library
# (scripts/stats/loc.py; -v: kernel/'s steps, each tests/, ...).
loc:
	scripts/stats/loc.py
loc-v:
	scripts/stats/loc.py -v

# Build and test in a fresh Ubuntu, as GitHub Actions does
# (.github/workflows/docker.yml).
build-docker:
	docker build -t "ix" .

build-docker-ocaml5:
	docker build -t "ix" --build-arg OCAML_VERSION=5.1.1 .

.PHONY: all test test-differential test-goken test-ocaml test-chidb test-pi clean loc loc-v build-docker build-docker-ocaml5

# mini-qemu against QEMU (plan_pi.md): 9pi's session, the Pi1 xv6
# ports' boots and graphics, the Pi4's boot and 16 of usertests' tests
# (on a copy of xv6 with 4MB of RAM, fast: xv6_pi4.py), and 3 on its
# four cores; mini-xv6's steps (kernel/test.sh: OCaml bare-metal on the
# Pi1, under mini-qemu and QEMU; ocaml-light cross-built once); needs
# ~/principia, ~/xv6 and the QEMUs (see raspberry/tests/). With
# XV6_USERTESTS=-u, the Pi1 ports' full usertests too.
test-pi: all
	dune build --profile release ./raspberry/Main.exe
	./raspberry/tests/9pi.py
	./raspberry/tests/9pi_graphics.py
	./raspberry/tests/xv6.sh $(XV6_USERTESTS)
	./raspberry/tests/graphics.py
	./raspberry/tests/xv6_pi4.py
	./raspberry/tests/xv6_pi4.py -smp 4 preempt pipe1 forktest
	./kernel/test.sh

# mini-git over the Internet: ix cloned from GitHub by mini-git (https,
# through curl), checked by git fsck and walk.
test-github: all
	rm -rf /tmp/ix-github && ./_build/default/version_control/Main.exe clone https://github.com/aryx/ix /tmp/ix-github
	git --git-dir=/tmp/ix-github/.git fsck --strict
	cd /tmp/ix-github && $(CURDIR)/_build/default/version_control/Main.exe walk -q
