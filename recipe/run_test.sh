#!/bin/bash

set -euxo pipefail
IFS=$'\n\t'

export NUMBA_DEVELOPER_MODE=1
export NUMBA_DISABLE_ERROR_MESSAGE_HIGHLIGHTING=1
export PYTHONFAULTHANDLER=1

# Windows runs the tests via run_test.bat (cmd); this script handles unix only.
SEGVCATCH=""
if [[ "$(uname)" == "Linux" ]]; then
  if command -v catchsegv >/dev/null 2>&1; then
    SEGVCATCH=catchsegv
  fi
  export CC="${CC} -pthread"
fi

TEST_NPROCS="${CPU_COUNT}"
FAST_TESTS="${FAST_TESTS:-0}"

# --- ppc64le ldexp/frexp quick-fail probe (numba#8489) -----------------------
# The suite at the end of this script runs with --random=0.25 (build 0) or 0.08
# on cross-compiled targets, so test_mathlib.TestMathLib.test_ldexp may never be drawn. Verify the
# ELFv2 signext fix directly, and fail fast and loudly here if it regresses.
#
# math.ldexp with a NEGATIVE exponent crosses the JIT -> numba_ldexp C helper
# boundary. Without the `signext` attribute on the i32 exponent argument, LLVM
# zero-extends it (clrldi), so -2 arrives as 4294967294 and the result is inf
# instead of 0.625. frexp is included as a control: its helper takes int* (a
# 64-bit pointer), which has no sub-word extension issue.
#
# np.ldexp is a SEPARATE declaration site from math.ldexp: the scalar path is
# declared in numba/cpython/mathimpl.py, while the ufunc path is declared in
# numba/np/math/mathimpl.py via numba/np/npyfuncs.py. A signext fix to one
# does not cover the other, so both are probed here.
python -c "
import math
import numpy as np
from numba import njit

@njit
def jit_ldexp(x, e):
    return math.ldexp(x, e)

@njit
def jit_np_ldexp(x, e):
    return np.ldexp(x, e)

@njit
def jit_frexp(x):
    return math.frexp(x)

failures = []
for x, e, want in ((2.5, -2, 0.625), (1.0, -1, 0.5), (2.5, 0, 2.5), (3.0, 4, 48.0)):
    got = jit_ldexp(x, e)
    print('ldexp(%r, %r) = %r  want %r' % (x, e, got, want))
    if got != want:
        failures.append('ldexp(%r, %r) -> %r != %r' % (x, e, got, want))

for x, e, want in ((2.5, -2, 0.625), (1.0, -1, 0.5), (2.5, 0, 2.5), (3.0, 4, 48.0)):
    got = jit_np_ldexp(x, e)
    print('np.ldexp(%r, %r) = %r  want %r' % (x, e, got, want))
    if got != want:
        failures.append('np.ldexp(%r, %r) -> %r != %r' % (x, e, got, want))

_INT32_MIN = -(2 ** 31)
for label, fn in (('ldexp', jit_ldexp), ('np.ldexp', jit_np_ldexp)):
    got = fn(2.5, _INT32_MIN)
    print('%s(2.5, INT32_MIN) = %r  want 0.0' % (label, got))
    if got != 0.0:
        failures.append('%s(2.5, INT32_MIN) -> %r != 0.0' % (label, got))

got = jit_frexp(0.625)
print('frexp(0.625) = %r  want (0.625, 0)' % (got,))
if got != (0.625, 0):
    failures.append('frexp(0.625) -> %r != (0.625, 0)' % (got,))

if failures:
    raise SystemExit('ppc64le ldexp/frexp ABI regression:' + ''.join(['\n  ' + f for f in failures]))
print('ldexp/np.ldexp/frexp signext probe OK')
"
# Run the upstream test explicitly too, since the sampled suite may not select it.
$SEGVCATCH python -m numba.runtests numba.tests.test_mathlib.TestMathLib.test_ldexp -v
# --- end ppc64le probe -------------------------------------------------------
# Check test discovery works
python -m numba.tests.test_runtests

# Disable NumPy AVX512_SKX dispatch when it is dispatchable and NumPy >= 1.22
# (avoids low-accuracy SVML libm replacements in ufunc loops).
_NPY_CMD='from numba.misc import numba_sysinfo;\
          sysinfo=numba_sysinfo.get_sysinfo();\
          print("AVX512_SKX" in sysinfo.get("NumPy Supported SIMD dispatch", ()) and
                sysinfo.get("NumPy Version", "0")>="1.22")'
if [[ "$(python -c "$_NPY_CMD")" == "True" ]]; then
  export NPY_DISABLE_CPU_FEATURES="AVX512_SKX"
fi

if [[ "$build_platform" != "$target_platform" && "$FAST_TESTS" == "0" ]]; then
  RANDOM_ARG="--random=0.25"
elif [[ "$build_platform" != "$target_platform" ]]; then
  RANDOM_ARG="--random=0.08"
elif [[ "$target_platform" == "osx-64" && "$FAST_TESTS" == "1" ]]; then
  RANDOM_ARG="--random=0.5"
else
  RANDOM_ARG=""
fi

$SEGVCATCH python -m numba.runtests -b $RANDOM_ARG --exclude-tags=long_running -m "$TEST_NPROCS"
