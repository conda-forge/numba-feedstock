@echo on

set "NUMBA_DEVELOPER_MODE=1"
set "NUMBA_DISABLE_ERROR_MESSAGE_HIGHLIGHTING=1"
set "PYTHONFAULTHANDLER=1"
@rem generic CPU avoids LLVM 20 OOM; reduced Windows test set; UTF-8 so that
@rem `numba -s` encodes correctly on a piped stdout (numba.tests.test_cli).
set "NUMBA_CPU_NAME=generic"
set "_NUMBA_REDUCED_TESTING=1"
set "PYTHONUTF8=1"

python -m numba.tests.test_runtests
if errorlevel 1 exit /b 1

<<<<<<< HEAD
@rem Vary which subset of tests --random selects across CI runs/architectures
@rem instead of always sampling the same fixed subset (numba's own default
@rem random_seed is a hardcoded 42 -- see recipe/patches/0002-...). python_version
@rem is folded in so that different python-version jobs building for the same
@rem target_platform within one CI run (same flow_run_id) get different, non-
@rem overlapping ~15%% samples instead of all re-testing the identical subset.
@rem Only override when running in real CI (flow_run_id set); local
@rem build-locally.py runs stay on numba's reproducible default for easier
@rem debugging.
if not "%flow_run_id%"=="" if not "%flow_run_id%"=="0" (
  for /f %%S in ('python -c "import os,zlib,sys; sys.stdout.write(str(zlib.crc32((os.environ.get('flow_run_id','0')+'-'+os.environ.get('target_platform','')+'-'+os.environ.get('python_version','')).encode())))"') do set "NUMBA_TEST_RANDOM_SEED=%%S"
)
if not "%flow_run_id%"=="" if not "%flow_run_id%"=="0" (
  echo Randomizing numba test selection: NUMBA_TEST_RANDOM_SEED=%NUMBA_TEST_RANDOM_SEED% ^(from flow_run_id=%flow_run_id% target_platform=%target_platform% python_version=%python_version%^)
)

=======
>>>>>>> upstream/main
@rem Windows: the test suite is sampled via --random to stay under the rattler-build post-test
@rem cleanup race (prefix-dev/rattler-build#2657). At high test volume rattler-build intermittently
@rem fails to remove its own test sandbox (Access is denied, os error 5). The failure probability
@rem scales with test volume and is NOT fixable in this recipe
@rem (holder is rattler's own in-sandbox handles, not anything the test script creates). ~10%%
@rem (FAST_TESTS, the normal build_number>=1 CI path) is reliably green; ~50%% (build_number==0)
@rem samples more and may occasionally need a Windows job re-run.
if "%FAST_TESTS%"=="1" (
<<<<<<< HEAD
  python -m numba.runtests -b --random=0.15 --exclude-tags=long_running -m %CPU_COUNT%
) else (
  python -m numba.runtests -b --random=0.55 --exclude-tags=long_running -m %CPU_COUNT%
=======
  python -m numba.runtests -b --random=0.1 --exclude-tags=long_running -m %CPU_COUNT%
) else (
  python -m numba.runtests -b --random=0.5 --exclude-tags=long_running -m %CPU_COUNT%
>>>>>>> upstream/main
)
if errorlevel 1 exit /b 1
