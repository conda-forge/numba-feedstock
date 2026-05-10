#!/bin/bash

set -e

export NUMBA_DEVELOPER_MODE=1
export NUMBA_DISABLE_ERROR_MESSAGE_HIGHLIGHTING=1
export PYTHONFAULTHANDLER=1

unamestr=`uname`
if [[ "$unamestr" == 'Linux' ]]; then
  SEGVCATCH=catchsegv
  export CC="${CC} -pthread"
elif [[ "$unamestr" == 'Darwin' ]]; then
  SEGVCATCH=""
else
  echo Error
fi

TEST_NPROCS=${CPU_COUNT}

# Validate Numba dependencies
python -m pip check

# Check Numba executables are there
numba -h

# run system info tool
numba -s

# Check test discovery works
python -m numba.tests.test_runtests

if [[ "$build_platform" != "$target_platform" ]]; then
	echo "Skipping numba test suite on $archstr because $build_platform != $host_platform"
else
	echo "Running all the tests except long_running on '$targt_platform'"

    # Disable NumPy dispatching to AVX512_SKX feature extensions if the chip is
    # reported to support the feature and NumPy >= 1.22 as this results in the use
    # of low accuracy SVML libm replacements in ufunc loops.
    _NPY_CMD='from numba.misc import numba_sysinfo;\
              sysinfo=numba_sysinfo.get_sysinfo();\
              print(sysinfo["NumPy AVX512_SKX detected"] and
                    sysinfo["NumPy Version"]>="1.22")'
    NUMPY_DETECTS_AVX512_SKX_NP_GT_122=$(python -c "$_NPY_CMD")
    echo "NumPy >= 1.22 with AVX512_SKX detected: $NUMPY_DETECTS_AVX512_SKX_NP_GT_122"

    if [[ "$NUMPY_DETECTS_AVX512_SKX_NP_GT_122" == "True" ]]; then
        export NPY_DISABLE_CPU_FEATURES="AVX512_SKX"
    fi

	echo "Running: $SEGVCATCH python -m numba.runtests -b -m $TEST_NPROCS -- $TESTS_TO_RUN"
    $SEGVCATCH python -m numba.runtests -b --exclude-tags='long_running' -m $TEST_NPROCS -- $TESTS_TO_RUN
fi
