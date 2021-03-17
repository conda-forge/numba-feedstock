#!/bin/bash

set -e

export NUMBA_DEVELOPER_MODE=1
export NUMBA_DISABLE_ERROR_MESSAGE_HIGHLIGHTING=1
export PYTHONFAULTHANDLER=1

unamestr=`uname`
if [[ "$unamestr" == 'Linux' ]]; then
  SEGVCATCH=catchsegv
elif [[ "$unamestr" == 'Darwin' ]]; then
  SEGVCATCH=""
else
  echo Error
fi

# limit CPUs in use on PPC64LE, fork() issues
# occur on high core count systems
archstr=`uname -m`
if [[ "$archstr" == 'ppc64le' ]]; then
    TEST_NPROCS=1
#elif [[ "$archstr" == 'aarch64' ]]; then
#    TEST_NPROCS=4
else
    TEST_NPROCS=${CPU_COUNT}
fi

# Check Numba executables are there
pycc -h
numba -h

# run system info tool
numba -s

# Check test discovery works
python -m numba.tests.test_runtests

if [[ "$archstr" == 'aarch64' ]]; then
	echo 'Running only a slice of tests'
	$SEGVCATCH python -m numba.runtests -b -j --random='0.15' --exclude-tags='long_running' -m $TEST_NPROCS -- numba.tests
# For now, skip tests on ppc64le because of known errors in the testing suite on ppc64le https://github.com/numba/numba/issues/4026
elif [[ "$archstr" == 'ppc64le' ]]; then
	echo 'Skipping tests on ppc64le for testing'
# Else run the whole test suite
else
	echo 'Running all the tests except long_running'
	echo "Running: $SEGVCATCH python -m numba.runtests -b -m $TEST_NPROCS -- $TESTS_TO_RUN"
$SEGVCATCH python -m numba.runtests -b --exclude-tags='long_running' -m $TEST_NPROCS -- $TESTS_TO_RUN
fi
