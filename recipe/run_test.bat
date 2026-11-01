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

@rem Windows: the test suite is sampled via --random to stay under the rattler-build post-test
@rem cleanup race (prefix-dev/rattler-build#2657). At high test volume rattler-build intermittently
@rem fails to remove its own test sandbox (Access is denied, os error 5). The failure probability
@rem scales with test volume and is NOT fixable in this recipe
@rem (holder is rattler's own in-sandbox handles, not anything the test script creates). ~10%%
@rem (FAST_TESTS, the normal build_number>=1 CI path) is reliably green; ~50%% (build_number==0)
@rem samples more and may occasionally need a Windows job re-run.
if "%FAST_TESTS%"=="1" (
  python -m numba.runtests -b --random=0.1 --exclude-tags=long_running -m %CPU_COUNT%
) else (
  python -m numba.runtests -b --random=0.5 --exclude-tags=long_running -m %CPU_COUNT%
)
if errorlevel 1 exit /b 1
