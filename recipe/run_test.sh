#!/bin/bash

set -e

export NUMBA_DEVELOPER_MODE=1
export NUMBA_DISABLE_ERROR_MESSAGE_HIGHLIGHTING=1
export PYTHONFAULTHANDLER=1

runtests=(
  python -m numba.runtests
  -b
  --exclude-tags='long_running'
)

unamestr=`uname`
if [[ "$unamestr" == 'Linux' ]]; then
  runtests=(catchsegv "${runtests[@]}")
  export CC="${CC} -pthread"
elif [[ "$unamestr" == 'Darwin' ]]; then
  :
else
  echo Error
fi

# limit CPUs in use on PPC64LE and AARCH64, fork() issues
# occur on high core count systems
archstr=`uname -m`
if [[ "$archstr" == 'ppc64le' ]]; then
    runtests+=(-m 1)
elif [[ "$archstr" == 'aarch64' ]]; then
    runtests+=(-m 4)
else
    runtests+=(-m ${CPU_COUNT})
fi

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

# Check Numba executables are there
pycc -h
numba -h

# run system info tool
numba -s

# Check test discovery works
python -m numba.tests.test_runtests

if [[ "$archstr" == 'aarch64' ]] || [[ "$archstr" == "ppc64le" ]]; then
  # Run tests verbosely to avoid Travis CI from killing it early
  if [[ "$archstr" == "ppc64le" ]]; then
    runtests+=(-v)
  fi
  echo 'Running only a slice of tests'
  runtests+=(-j --random='0.15' -- numba.tests)
# Else run the whole test suite
else
  echo 'Running all the tests except long_running'
  runtests+=(--)
fi

echo "Running: ${runtests[*]}"
# Oddly enough, Travis CI seems to buffer stderr output more than stdout;
# So, to avoid early job terminations, redirect stderr to unbuffered stdout
PYTHONUNBUFFERED=1 2>&1 \
  "${runtests[@]}"

pip check
