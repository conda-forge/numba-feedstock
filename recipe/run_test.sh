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

# --- ppc64le fix guards (conda-forge/numba-feedstock#192) ---------------------
if [[ "${target_platform:-}" == "linux-ppc64le" ]]; then
  # Deterministic fast guard on the two ppc64le test FIXES (patches 0005 and
  # 0006): run them up front so a regression in the patched expected value
  # fails in seconds -- and so they are always checked even on the random test
  # slices that would otherwise exclude them. The QEMU-artifact SKIPS (0003,
  # 0004, 0007) need no guard here. See conda-forge/numba-feedstock#192.
  echo "VERIFY: ppc64le test fixes (test_inlining_global_dispatcher, test_array_const_alignment) -- #192"
  $SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -v \
    numba.tests.test_function_type.TestInliningFunctionType.test_inlining_global_dispatcher \
    numba.tests.test_array_constants.TestConstantArray.test_array_const_alignment
fi
# ------------------------------------------------------------------------------

TEST_NPROCS="${CPU_COUNT}"
FAST_TESTS="${FAST_TESTS:-0}"

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
${QEMU_EXECVE} ${PYTHON} -m numba.tests.test_runtests

# Disable NumPy AVX512_SKX dispatch when it is dispatchable and NumPy >= 1.22
# (avoids low-accuracy SVML libm replacements in ufunc loops).
_NPY_CMD='from numba.misc import numba_sysinfo;\
          sysinfo=numba_sysinfo.get_sysinfo();\
          print("AVX512_SKX" in sysinfo.get("NumPy Supported SIMD dispatch", ()) and
                sysinfo.get("NumPy Version", "0")>="1.22")'
if [[ "$("${QEMU_EXECVE}" ${PYTHON} -c "$_NPY_CMD")" == "True" ]]; then
  export NPY_DISABLE_CPU_FEATURES="AVX512_SKX"
fi

# Vary which subset of tests --random selects across CI runs/architectures
if [[ -n "${flow_run_id:-}" && "${flow_run_id}" != "0" ]]; then
  NUMBA_TEST_RANDOM_SEED="$(echo -n "${flow_run_id}-${target_platform}-${python_version}" | cksum | cut -d' ' -f1)"
  export NUMBA_TEST_RANDOM_SEED
  echo "Randomizing numba test selection: NUMBA_TEST_RANDOM_SEED=${NUMBA_TEST_RANDOM_SEED} (from flow_run_id=${flow_run_id} target_platform=${target_platform} python_version=${python_version})"
fi

if [[ "$build_platform" != "$target_platform" && "$FAST_TESTS" == "1" ]]; then
  RANDOM_ARG="--random=0.15"  # ~ 1:49hr for ppc64le on x86_64, 55m on aarch64! \o/, true random + 5 builds should help more coverage
elif [[ "$build_platform" != "$target_platform" && "$FAST_TESTS" == "0" ]]; then
  RANDOM_ARG="--random=0.25"
elif [[ "$target_platform" == "osx-64" && "$FAST_TESTS" == "1" ]]; then
  RANDOM_ARG="--random=0.5"
else
  RANDOM_ARG=""
fi

$SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -b $RANDOM_ARG --exclude-tags=long_running -m "$TEST_NPROCS"
