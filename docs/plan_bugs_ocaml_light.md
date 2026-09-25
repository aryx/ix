# Bugs and limits found in ocaml-light, from ix

mini-xv6 (`kernel/`, [`plans/plan_kernel.md`](plans/plan_kernel.md))
runs OCaml bare-metal on the Pi1 with ocaml-light (`~/ocaml-light`)
cross-compiled for arm (`kernel/ocaml-light.sh`: a clone configured
with `-target-arch arm`). What its first step found (2026-09-25), for
the author to decide. Each has a workaround in `kernel/step1/`.

## 1. `-output-obj` calls the host's `ld -r` when cross-compiling (a bug)

**What**: `ocamlopt -output-obj` links the OCaml modules into one
object with the partial linker from `utils/config.ml`'s
`native_partial_linker`, which `configure` sets to `ld -r` whatever the
target. With `-target-arch arm` on an aarch64 host, that is the
aarch64 `ld`, which refuses the arm objects:

```
ld: /tmp/camlstartup0.o: error adding symbols: file in wrong format
```

**Fix**: `configure`'s `-target-arch` cases could set PARTIALLD to the
cross toolchain's (`arm-linux-gnueabihf-ld -r`, `aarch64-linux-gnu-ld
-r`, ...), as they set AS and NATIVECC.

**Workaround** (`kernel/step1/Makefile`): an `ld` symbolic link to
`arm-linux-gnueabihf-ld`, first in PATH when calling ocamlopt.

## 2. The arm target is ARMv7 and VFPv3 only (a limit)

`configure`'s arm case compiles the runtime with `-march=armv7-a
-mfpu=vfpv3-d16 -mfloat-abi=hard` and assembles with the same. The
Pi1's ARM1176 is ARMv6KZ with VFPv2. The code ocaml-light's arm backend
emits, and `asmrun/arm.S`, use no ARMv7-only instruction (no movw/movt,
sdiv, ldrex, dmb; checked by grep, and the kernel runs on QEMU's and
mini-qemu's ARM1176), so the ARMv6 build is only a matter of flags:
`kernel/step1/Makefile` compiles the runtime itself with
`-march=armv6kz -mfpu=vfp`. A `-target-arch armv6` (or an `-march`
option) would make it a supported target.

## 3. `List.init` is not tail recursive (a limit)

`List.init 100000 f` recurses 100,000 frames deep: on a Linux stack
(8MB) it works; on a kernel's (64KB here) it overflows. Today's OCaml's
`List.init` switches to a tail-recursive version above 10,000
elements. Worth doing the same, or saying so in `list.mli`.

## 4. A cross build takes Int64's C type from the host (a bug)

**What**: configured on an aarch64 host with `-target-arch arm`,
`config/m.h` says `#define ARCH_INT64_TYPE long`: `configure` probed
the *host's* compiler, where `long` has 64 bits; on the arm32 target it
has 32, so the runtime's `int64` operations there would be 32-bit ones
(found 2026-09-25, `kernel/xv6`: its Pi1 build uses no Int64 because of
it, the fault registers cross from C already formatted).

**Fix**: as for issue 1, the target's facts from the target: under
`-target-arch arm`, `long long` (or a probe compiled with the cross
compiler, `sizeof` read from its object, as autoconf does).

**Workaround**: none needed while the kernel avoids Int64 on the Pi1;
the Pi4's build (`-target-arch arm64` on this aarch64 host) is native
and right.

## Not ocaml-light's, found on the way

- **Ubuntu's armhf libgcc is Thumb-2 for ARMv7**: an ARMv6 cannot run
  its division routines (`blx __udivsi3` switches to Thumb). Linking a
  kernel for the Pi1 needs other ones: `kernel/step1/libc.c` has them
  (the ABI's `__aeabi_*`, and the older `__divsi3`, `__modsi3` that
  ocaml-light's arm backend calls for `/` and `mod`).
- Number literals with `_` (`100_000`) are not accepted: OCaml 1.07's
  lexer. Not a bug; a difference to know when porting code.
- **GCC vectorizes the runtime's C for arm64** (Advanced SIMD `movi`,
  `ldr q`): mini-qemu's arm64 does the scalar floating point only, so
  `kernel/xv6`'s Pi4 build compiles the runtime with
  `-fno-tree-vectorize`.
