#!/bin/bash

set -euxo pipefail
IFS=$'\n\t'

# --- run the guest under qemu-execve, not vanilla qemu (reverts #201) --------
# qemu-execve-ppc64le 11.0.3 build 5 is arch-aware: it forwards execve() of a
# NATIVE build-platform binary straight to the host kernel, and only routes
# FOREIGN ppc64le ELFs back through emulation. That fixes what #201 hit with
# the older build, where every guest execve was intercepted indiscriminately
# and guest python therefore could not exec the build-platform cross-compiler.
#
# The guest must be LAUNCHED BY qemu-execve for interception to exist at all --
# it is a property of the emulating process, not of any environment variable.
# Launching with the vanilla qemu-ppc64le shipped in the same package leaves a
# guest whose own execve() syscalls go straight to the aarch64 host kernel,
# which cannot run a ppc64le ELF, so tests that spawn sys.executable themselves
# (test_pycc, test_parallel_backend) die with
# "OSError: [Errno 8] Exec format error".
#
# This also removes any dependence on kernel binfmt_misc, which conda-smithy's
# generated .github/workflows/conda-build.yml registers only on x86_64 hosts --
# never on the aarch64 hosts that actually run the ppc64le lanes
# (conda-forge.yml sets build_platform: linux_ppc64le -> linux_aarch64).
# See conda-forge/numba-feedstock#201 and #203.
export CROSSCOMPILING_EMULATOR="${QEMU_EXECVE}"
#
# Native-arch passthrough is OPT-IN and needs BOTH gates: QEMU_EXECVE non-empty
# (else execve dispatch never reaches qemu_execve() at all) and
# QEMU_EXECVE_NATIVE_PASSTHROUGH set. Without the second gate, a guest process
# exec'ing a NATIVE build-platform binary -- e.g. test_pycc / test_cffi invoking
# $BUILD_PREFIX/bin/powerpc64le-conda-linux-gnu-cc, which is an aarch64 driver
# that merely EMITS ppc64le -- falls through to qemu's standard ELF arch check
# and dies with "Invalid ELF image for this architecture". The qemu-execve
# package sets no default for either variable; the invoking environment must
# supply both. Harmless on native lanes, where QEMU_EXECVE is empty and
# qemu_execve() is never reached.
export QEMU_EXECVE_NATIVE_PASSTHROUGH=1

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

# --- qemu-execve native-passthrough quick-fail (conda-forge/numba-feedstock#203)
# Cheapest possible check that the native-arch passthrough gate set above is
# actually armed: make the GUEST python exec a NATIVE build-platform binary --
# the cross-compiler driver, an aarch64 executable that merely EMITS ppc64le.
# That nested execve is the exact operation that killed the whole
# test_pycc/test_cffi family in #203 ("Invalid ELF image for this
# architecture"). Probing it directly compiles nothing and costs a fraction of
# a second, so a broken gate fails HERE instead of ~40s later in the toolchain
# block below -- and it is cheap enough to run locally before pushing to CI.
#
# ${CC} has "-pthread" appended above, so strip arguments before exec'ing it.
# The path is passed as sys.argv[1] rather than interpolated into the -c source
# to avoid nested-quoting breakage.
_CC_BIN="${CC:-}"
_CC_BIN="${_CC_BIN%% *}"
if [[ -n "${QEMU_EXECVE:-}" && -n "${_CC_BIN}" ]]; then
  echo "VERIFY: qemu-execve native-arch passthrough (guest exec of ${_CC_BIN}) -- #203"
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1], "--version"])' \
    "${_CC_BIN}"
fi
# --- end native-passthrough quick-fail ---------------------------------------

# --- test_pycc failure triage probe (conda-forge/numba-feedstock#203) ---------
# The quick-fail above proves only that the guest can START the native cross-cc
# driver. It does not show whether that driver can then do its job. Two very
# different faults both surface as "the test_pycc family dies", and they have
# opposite fixes -- this block tells them apart in one CI run:
#
#   (A) RESOLUTION. The native driver starts but cannot find its own children
#       (cc1, as, collect2/ld) because the guest environment does not carry
#       $BUILD_PREFIX's exec dirs in PATH/COMPILER_PATH. The fix is environment,
#       right here in run_test.sh, and patch skip-test_compile_nrt-on-ppc64le's skip of TestDistutilsSupport
#       /test_compile_nrt would then be unnecessary rather than load-bearing.
#
#   (B) FOREIGN EXEC BELOW THE HANDOFF. The driver works and emits a valid
#       ppc64le binary, but nothing under it can RUN one. Native passthrough
#       hands the driver straight to the host kernel, which ends qemu-execve's
#       interception for that entire subtree, so any ppc64le ELF exec'd further
#       down gets no emulator. That is not fixable in this recipe: qemu-execve
#       would need an LD_PRELOAD shim to re-inject emulation into native
#       children.
#
# Every step is non-fatal (|| echo) so a single push reports ALL of them rather
# than stopping at the first. Read top-to-bottom: the first FAIL names the class.
if [[ -n "${QEMU_EXECVE:-}" && -n "${_CC_BIN:-}" ]]; then
  echo "PROBE: test_pycc triage -- resolution vs foreign-exec -- #203"
  _PROBE_DIR="$(mktemp -d)"
  printf 'int main(void){return 0;}\n' > "${_PROBE_DIR}/probe.c"

  # Step 1 -- the driver's own view of its search paths, read from INSIDE the
  # guest. This is the direct readout for fault class (A): if cc1 resolves to a
  # bare name rather than an absolute path, PATH/COMPILER_PATH is the problem.
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1], "-print-search-dirs"])' \
    "${_CC_BIN}" || echo "PROBE FAIL step1: guest cannot query driver search dirs"
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1], "-print-prog-name=cc1"])' \
    "${_CC_BIN}" || echo "PROBE FAIL step1b: guest cannot resolve cc1"

  # Step 2 -- COMPILE. Forces the native driver to exec its own children (cc1,
  # as). A failure here naming cc1/as/ld is fault class (A), RESOLUTION.
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1], "-c", sys.argv[2], "-o", sys.argv[3]])' \
    "${_CC_BIN}" "${_PROBE_DIR}/probe.c" "${_PROBE_DIR}/probe.o" \
    && echo "PROBE OK step2: guest-driven native cc produced an object" \
    || echo "PROBE FAIL step2: compile failed -- fault class (A), RESOLUTION"

  # Step 3 -- LINK an executable. Forces collect2/ld on top of step 2.
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1], sys.argv[2], "-o", sys.argv[3]])' \
    "${_CC_BIN}" "${_PROBE_DIR}/probe.c" "${_PROBE_DIR}/probe_exe" \
    && echo "PROBE OK step3: guest-driven native cc linked an executable" \
    || echo "PROBE FAIL step3: link failed -- fault class (A), RESOLUTION"

  # Confirm what was actually produced, so a green step2/step3 cannot be
  # mistaken for a driver that silently emitted host-arch output.
  file "${_PROBE_DIR}/probe_exe" 2>/dev/null || echo "PROBE note: 'file' unavailable"

  # Step 4 -- the decisive one. The GUEST execs the ppc64le binary it just
  # built. The guest was launched by qemu-execve, so its own execve is still
  # intercepted; this should succeed even under fault class (B).
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call([sys.argv[1]])' \
    "${_PROBE_DIR}/probe_exe" \
    && echo "PROBE OK step4: guest exec of a fresh ppc64le binary works" \
    || echo "PROBE FAIL step4: guest cannot exec its own ppc64le output"

  # Step 5 -- the LD_PRELOAD question, isolated. Route the same exec through a
  # NATIVE intermediary (/bin/sh, taken by passthrough to the host kernel).
  # step4 OK + step5 FAIL is the signature of fault class (B): interception
  # survives in the guest but is lost the moment a native child is handed off.
  ${QEMU_EXECVE} ${PYTHON} -c \
    'import subprocess, sys; subprocess.check_call(["/bin/sh", "-c", "exec \"$0\"", sys.argv[1]])' \
    "${_PROBE_DIR}/probe_exe" \
    && echo "PROBE OK step5: native child can exec a ppc64le binary (no shim needed)" \
    || echo "PROBE FAIL step5: fault class (B), FOREIGN EXEC BELOW HANDOFF -- qemu-execve needs an LD_PRELOAD shim"

  rm -rf "${_PROBE_DIR}"
  unset _PROBE_DIR
fi
unset _CC_BIN
# --- end test_pycc failure triage probe --------------------------------------

# --- unresolved-skip triage block (conda-forge/numba-feedstock#203) -----------
# The tests whose disposition is still open, run BY NAME and UNSAMPLED on every
# EMULATED lane. Supersedes the old ppc64le-gated skip audit and the separate
# fork gate: one block serves both lanes, because what differs per lane is the
# PATCH SET, not this block.
#
#   Lane where skip-test_unique-on-ppc64le/skip-test_compile_nrt-on-ppc64le ARE applied (ppc64le): these self-skip, and this block
#   is an AUDIT -- it proves "skipped", which a --random sampled log otherwise
#   cannot distinguish from "never drawn".
#   Lane where they are NOT applied: they may genuinely EXECUTE, which is the
#   open experiment -- are these QEMU gaps emulation-general, or specific to
#   QEMU's POWER target?
#
# CAVEAT LEARNED THE HARD WAY: "not applied" does NOT guarantee "executes".
# numba upstream carries @skip_if_linux_aarch64 on test_compile_nrt and
# TestDistutilsSupport, so on aarch64 those self-skip regardless of our patches
# and this lane CANNOT answer the skip-test_compile_nrt-on-ppc64le question at all. Read the verdicts below
# literally -- SKIPPED is inconclusive, not evidence.
_triage_verdict() {
  # $1 label, $2 note-if-passed, rest = command to run.
  # A unittest run exits 0 in THREE distinct ways and only one is a pass:
  #   "Ran 0 tests"    -> `-k` matched nothing; the check was vacuous
  #   "OK (skipped=N)" -> ran, but every selected test self-skipped
  #   "OK"             -> genuinely executed and passed
  # Judging by exit status alone conflates all three. An earlier revision of
  # this block did exactly that and reported four skipped tests as "passed".
  local _label="$1"; shift
  local _note="$1"; shift
  # Optional failure-note override: set by the caller as a temporary
  # environment assignment on the call itself, e.g.
  #   _TRIAGE_FAIL_NOTE="..." _triage_verdict "$label" "$note" cmd...
  # This is NOT a positional parameter -- it cannot collide with or
  # swallow the first word of "$@" (the command), which is what a
  # third positional arg would risk at every call site that omits it.
  local _note_fail="${_TRIAGE_FAIL_NOTE:-the gap DOES reproduce on this target}"
  local _out
  local _rc
  set +e
  _out="$("$@" 2>&1)"
  _rc=$?
  set -e
  printf '%s\n' "${_out}"
  if grep -qE '^Ran 0 tests' <<<"${_out}"; then
    _TRIAGE_LAST="NOTHING_SELECTED"
    echo "TRIAGE NOTHING_SELECTED: ${_label} -- pattern matched no test, INCONCLUSIVE (upstream rename?)"
  elif grep -qE '^OK \(skipped=' <<<"${_out}"; then
    _TRIAGE_LAST="SKIPPED"
    echo "TRIAGE SKIPPED: ${_label} -- INCONCLUSIVE, did not execute. Reason(s):"
    grep -oE "skipped '[^']*'" <<<"${_out}" | sort -u | sed 's/^/  /'
  elif [[ ${_rc} -eq 0 ]]; then
    _TRIAGE_LAST="PASSED"
    echo "TRIAGE PASSED: ${_label} -- ${_note}"
  else
    _TRIAGE_LAST="FAILED"
    echo "TRIAGE FAILED: ${_label} -- ${_note_fail}"
  fi
}

if [[ -n "${QEMU_EXECVE:-}" ]]; then
  echo "TRIAGE: unresolved skip candidates (skip-test_unique-on-ppc64le, skip-test_compile_nrt-on-ppc64le) + fork gate -- #203"
  _TRIAGE_LAST=""

  _triage_verdict "test_unique (skip-test_unique-on-ppc64le)" \
    "gap does NOT reproduce here; skip-test_unique-on-ppc64le unjustified on this target" \
    ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_unique \
    numba.tests.test_array_methods

  _triage_verdict "test_compile_nrt (skip-test_compile_nrt-on-ppc64le)" \
    "gap does NOT reproduce here; skip-test_compile_nrt-on-ppc64le unjustified on this target" \
    ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_compile_nrt \
    numba.tests.test_pycc

  _TRIAGE_FAIL_NOTE="REGRESSION: this class is expected to pass under emulation" \
  _triage_verdict "TestDistutilsSupport (no longer skipped under emulation)" \
    "regression guard: this class is deliberately NOT skipped under emulation and is expected to pass here" \
    ${QEMU_EXECVE} ${PYTHON} -m unittest -v \
    numba.tests.test_pycc.TestDistutilsSupport

  # FATAL -- the build-7 fork fix gate. The fork-fix patch (formerly 0004) was
  # retired on the strength of qemu-execve build 7, so anything other than a
  # GENUINE pass must stop the lane: a skip or a zero-match here would leave that
  # removal unverified, which is indistinguishable from a silent regression.
  _triage_verdict "fork gate (qemu-execve >=7)" \
    "build-7 fork fix confirmed; the fork-fix patch stays retired" \
    $SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m unittest -v \
    -k test_workqueue_handles_fork_from_non_main_thread \
    numba.tests.test_parallel_backend
  if [[ "${_TRIAGE_LAST}" != "PASSED" ]]; then
    echo "TRIAGE FATAL: fork gate verdict was ${_TRIAGE_LAST}, not PASSED -- restore the fork-fix patch"
    exit 1
  fi
fi

# --- ppc64le fix guards (conda-forge/numba-feedstock#192) ---------------------
# Runs HERE -- before the forefronted known-red block -- because that block
# includes test_recursion, which costs ~791s under emulation; the old position
# after it made the "fails in seconds" guarantee false. Also placed ABOVE the
# NUMBA_CF_TRIAGE early exit so triage mode checks these too, same as the
# unresolved-skip triage block above.
#
# These are test FIXES, not skips: a SKIPPED or NOTHING_SELECTED verdict means
# the patched expected value no longer matches upstream/LLVM on this target and
# must fail the lane -- same reasoning as the fork gate above. Each test is
# classified separately via _triage_verdict (defined above) rather than judged
# by combined exit status alone.
#
# Note: _triage_verdict's PASSED branch falls back to plain exit-status when
# numba.runtests does not emit the "Ran 0 tests" / "OK (skipped=" summary
# lines it looks for -- so behaviour never degrades below today's exit-status
# check, only improves on it.
if [[ "${target_platform:-}" == "linux-ppc64le" ]]; then
  echo "VERIFY: ppc64le test fixes (test_inlining_global_dispatcher, test_array_const_alignment) -- #192"

  _triage_verdict "test_inlining_global_dispatcher (fix-test_inlining_global_dispatcher-bb-count-on-ppc64le)" \
    "patched BB-count expectation still matches ppc64le LLVM" \
    $SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -v \
    numba.tests.test_function_type.TestInliningFunctionType.test_inlining_global_dispatcher
  if [[ "${_TRIAGE_LAST}" != "PASSED" ]]; then
    echo "VERIFY FATAL: test_inlining_global_dispatcher (fix-test_inlining_global_dispatcher-bb-count-on-ppc64le) verdict was ${_TRIAGE_LAST}, not PASSED -- patch fix-test_inlining_global_dispatcher-bb-count-on-ppc64le expectation has rotted"
    exit 1
  fi

  _triage_verdict "test_array_const_alignment (fix-test_array_const_alignment-globalmerge-on-ppc64le)" \
    "patched GlobalMerge alignment expectation still matches ppc64le LLVM" \
    $SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -v \
    numba.tests.test_array_constants.TestConstantArray.test_array_const_alignment
  if [[ "${_TRIAGE_LAST}" != "PASSED" ]]; then
    echo "VERIFY FATAL: test_array_const_alignment (fix-test_array_const_alignment-globalmerge-on-ppc64le) verdict was ${_TRIAGE_LAST}, not PASSED -- patch fix-test_array_const_alignment-globalmerge-on-ppc64le expectation has rotted"
    exit 1
  fi
fi
# ------------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# FOCUSED test_unique CASE REPRODUCER  (opt-in: NUMBA_CF_REPRO=1)
#
# Python faulthandler localised the ppc64le SIGSEGV to ONE check() call in
# numba.tests.test_array_methods.test_unique -- original line 1884,
# check(np.array(['A', 'A', 'B'], dtype='<U16'))  # issue 10250
# i.e. np.unique over a UNICODE array, NOT the numeric sort path.
#
# This block replays EVERY check() call of the real test, each in a SEPARATE
# process, so one crash cannot mask the remaining cases. Each case runs the
# pure-Python call BEFORE the jitted one, flushed, so a fault between "PY" and
# "JIT" pins the failure to JIT-compiled code.
#
# Cheap by design: small arrays, ~7 short probes, no full battery needed.
# ---------------------------------------------------------------------------
if [[ -n "${QEMU_EXECVE:-}" && "${NUMBA_CF_REPRO:-0}" == "1" ]]; then
  echo "REPRO: ============ BEGIN test_unique CASE REPRODUCER ============"

  _repro_case() {
    local _label="$1"; shift
    local _expr="$1"; shift
    _TRIAGE_FAIL_NOTE="CRASHES: np.unique fails on ${_label}" \
    _triage_verdict "np.unique case: ${_label}" \
      "clean: np.unique handles ${_label}" \
      ${QEMU_EXECVE} ${PYTHON} -c "
import numpy as np
from numba import njit
def np_unique(a):
    return np.unique(a)
cfunc = njit(cache=False)(np_unique)
a = ${_expr}
print('PY  ', np_unique(a), flush=True)
print('JIT ', cfunc(a), flush=True)
print('CASE_OK', flush=True)
"
  }

  _repro_case "2D int" \
    "np.array([[1, 1, 3], [3, 4, 5]])"
  _repro_case "zeros(5)" \
    "np.array(np.zeros(5))"
  _repro_case "2D float" \
    "np.array([[3.1, 3.1], [1.7, 2.29], [3.3, 1.7]])"
  _repro_case "empty" \
    "np.array([])"
  _repro_case "nan pair" \
    "np.array([np.nan, np.nan])"
  _repro_case "U16 unicode" \
    "np.array(['A', 'A', 'B'], dtype='<U16')"
  _repro_case "datetime64 with NAT" \
    "np.array([np.datetime64('2001-01-01'), np.datetime64('2001-01-01'), np.datetime64('2001-01-02'), np.datetime64('NAT')])"

  echo "REPRO: ============= END test_unique CASE REPRODUCER ============="
fi

# ---------------------------------------------------------------------------
# ppc64le DIAGNOSTIC BATTERY  (opt-in: NUMBA_CF_DIAG=1)
#
# Purpose: distinguish (a) an LLVM PPC64LE codegen bug from (b) a QEMU ppc64le
# TCG / ISA-coverage bug, for test_unique (SIGSEGV rc=139) and test_compile_nrt
# (SIGILL rc=132). SIGILL in particular suggests LLVM is emitting instructions
# for a CPU model QEMU advertises but does not faithfully execute.
#
# Every line is prefixed "DIAG:" so results can be grepped out of the build log.
# Skipped entirely unless NUMBA_CF_DIAG=1, so the normal triage loop is unaffected.
# ---------------------------------------------------------------------------
if [[ -n "${QEMU_EXECVE:-}" && "${NUMBA_CF_DIAG:-0}" == "1" ]]; then
  echo "DIAG: ======================= BEGIN DIAGNOSTIC BATTERY ======================="

  # Run a command, never abort the script, always report its rc.
  _diag() {
    local _l="$1"; shift
    echo "DIAG: ---- BEGIN ${_l} ----"
    set +e
    "$@" 2>&1
    local _rc=$?
    set -e
    echo "DIAG: ---- END ${_l} rc=${_rc} ----"
  }

  # --- SECTION A: what does the emulated environment claim to be? -----------
  _diag "A1 uname/platform" \
    ${QEMU_EXECVE} ${PYTHON} -c "import os,platform;print(os.uname());print('machine=',platform.machine(),'processor=',platform.processor())"

  _diag "A2 llvmlite host cpu + features" \
    ${QEMU_EXECVE} ${PYTHON} -c "
import llvmlite.binding as llvm
try:
    print('LLVM_VERSION', llvm.llvm_version_info, flush=True)
except Exception as e:
    print('LLVM_VERSION_ERR', repr(e), flush=True)
try:
    print('HOST_CPU', llvm.get_host_cpu_name(), flush=True)
except Exception as e:
    print('HOST_CPU_ERR', repr(e), flush=True)
try:
    print('HOST_FEATURES', llvm.get_host_cpu_features().flatten(), flush=True)
except Exception as e:
    print('HOST_FEATURES_ERR', repr(e), flush=True)
"

  _diag "A2b numba resolved cpu config" \
    ${QEMU_EXECVE} ${PYTHON} -c "
import numba
from numba import config as _c
print('NUMBA_CFG_CPU_NAME', getattr(_c, 'CPU_NAME', '<none>'), flush=True)
print('NUMBA_CFG_CPU_FEATURES', getattr(_c, 'CPU_FEATURES', '<none>'), flush=True)
print('NUMBA_VERSION', numba.__version__, flush=True)
"

  _diag "A3 auxv hwcap (AT_HWCAP=16 AT_HWCAP2=26 AT_PLATFORM=15 AT_BASE_PLATFORM=24)" \
    ${QEMU_EXECVE} ${PYTHON} -c "import ctypes;l=ctypes.CDLL(None);l.getauxval.restype=ctypes.c_ulong;l.getauxval.argtypes=[ctypes.c_ulong];print('AT_HWCAP ',hex(l.getauxval(16)));print('AT_HWCAP2',hex(l.getauxval(26)));print('AT_PLATFORM',ctypes.cast(l.getauxval(15),ctypes.c_char_p).value);print('AT_BASE_PLATFORM',ctypes.cast(l.getauxval(24),ctypes.c_char_p).value)"

  _diag "A4 /proc/cpuinfo as seen INSIDE emulation" \
    ${QEMU_EXECVE} ${PYTHON} -c "print(open('/proc/cpuinfo').read())"

  _diag "A5 ld show auxv" \
    env LD_SHOW_AUXV=1 ${QEMU_EXECVE} ${PYTHON} -c "pass"

  _diag "A6 numba sysinfo" \
    ${QEMU_EXECVE} ${PYTHON} -m numba -s

  _diag "A7 qemu version" \
    ${QEMU_EXECVE} --version

  # --- SECTION B: LLVM-side CPU ladder x the two crashing tests -------------
  # A pass here means "this setting avoids the crash" = a LEAD, so the
  # failure note is inverted relative to the normal skip-audit probes.
  for _cpu in generic pwr8 pwr9 pwr10; do
    _TRIAGE_FAIL_NOTE="NUMBA_CPU_NAME=${_cpu} does NOT avoid the crash" \
    _triage_verdict "test_unique @ NUMBA_CPU_NAME=${_cpu}" \
      "NUMBA_CPU_NAME=${_cpu} AVOIDS the crash -- LLVM was targeting features QEMU mis-executes" \
      env NUMBA_CPU_NAME="${_cpu}" NUMBA_CPU_FEATURES="" ${SEGVCATCH:-} ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_unique numba.tests.test_array_methods

    _TRIAGE_FAIL_NOTE="NUMBA_CPU_NAME=${_cpu} does NOT avoid the crash" \
    _triage_verdict "test_compile_nrt @ NUMBA_CPU_NAME=${_cpu}" \
      "NUMBA_CPU_NAME=${_cpu} AVOIDS the crash -- LLVM was targeting features QEMU mis-executes" \
      env NUMBA_CPU_NAME="${_cpu}" NUMBA_CPU_FEATURES="" ${SEGVCATCH:-} ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_compile_nrt numba.tests.test_pycc
  done

  # --- SECTION C: QEMU-side CPU ladder (emulator ISA level) -----------------
  # If a LOWER QEMU_CPU avoids the crash, the emulator's TCG coverage for the
  # higher ISA level is implicated rather than LLVM correctness.
  # NOTE: power8 is NOT testable here -- the conda glibc requires ISA 3.00 (POWER9+)
  # and aborts with "Fatal glibc error: CPU lacks ISA 3.00 support" before any test runs.
  for _qcpu in power9 power10; do
    _diag "C-detect llvmlite HOST_CPU under QEMU_CPU=${_qcpu}" \
      env QEMU_CPU="${_qcpu}" ${QEMU_EXECVE} ${PYTHON} -c "
import llvmlite.binding as llvm
try:
    print('HOST_CPU', llvm.get_host_cpu_name(), flush=True)
except Exception as e:
    print('HOST_CPU_ERR', repr(e), flush=True)
"

    _TRIAGE_FAIL_NOTE="QEMU_CPU=${_qcpu} does NOT avoid the crash" \
    _triage_verdict "test_unique @ QEMU_CPU=${_qcpu}" \
      "QEMU_CPU=${_qcpu} AVOIDS the crash -- emulator ISA coverage implicated" \
      env QEMU_CPU="${_qcpu}" ${SEGVCATCH:-} ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_unique numba.tests.test_array_methods
  done

  # --- SECTION D: optimisation / vectorisation knobs ------------------------
  for _opt in 0 1 2; do
    _TRIAGE_FAIL_NOTE="NUMBA_OPT=${_opt} does NOT avoid the crash" \
    _triage_verdict "test_unique @ NUMBA_OPT=${_opt}" \
      "NUMBA_OPT=${_opt} AVOIDS the crash -- optimiser-generated code implicated" \
      env NUMBA_OPT="${_opt}" ${SEGVCATCH:-} ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_unique numba.tests.test_array_methods
  done

  _TRIAGE_FAIL_NOTE="disabling vectorisation does NOT avoid the crash" \
  _triage_verdict "test_unique @ no loop/SLP vectorise" \
    "disabling vectorisation AVOIDS the crash -- vector (VSX/Altivec) codegen implicated" \
    env NUMBA_LOOP_VECTORIZE=0 NUMBA_SLP_VECTORIZE=0 ${SEGVCATCH:-} ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_unique numba.tests.test_array_methods

  # --- SECTION E: is it JIT-compiled code at all? ---------------------------
  _TRIAGE_FAIL_NOTE="STILL crashes with the JIT disabled -- NOT numba codegen; look at numpy/libc under emulation" \
  _triage_verdict "test_unique @ NUMBA_DISABLE_JIT=1" \
    "JIT-disabled run is clean -- the fault IS in JIT-compiled machine code" \
    env NUMBA_DISABLE_JIT=1 ${SEGVCATCH:-} ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_unique numba.tests.test_array_methods

  # --- SECTION F: narrow the failing operation ------------------------------
  _diag "F1 minimal np.unique / np.sort by dtype and size" \
    ${SEGVCATCH:-} ${QEMU_EXECVE} ${PYTHON} -c "
import numpy as np
from numba import njit
@njit(cache=False)
def u(a):
    return np.unique(a)
@njit(cache=False)
def s(a):
    return np.sort(a)
for dt in ('int8','int32','int64','float32','float64'):
    for n in (1, 7, 64, 1000):
        a = np.arange(n, dtype=dt)[::-1].copy()
        print('SORT', dt, n, flush=True)
        s(a)
        print('UNIQUE', dt, n, flush=True)
        u(a)
print('F1_ALL_OK', flush=True)
"

  # --- SECTION G: dump the emitted PPC64LE assembly for the sort path -------
  _diag "G1 emitted asm for np.sort (truncated by the harness, grep 'DIAG:' context)" \
    env NUMBA_DUMP_ASSEMBLY=1 ${QEMU_EXECVE} ${PYTHON} -c "
import numpy as np
from numba import njit
@njit(cache=False)
def s(a):
    return np.sort(a)
s(np.arange(64, dtype='int64')[::-1].copy())
"

  # --- SECTION H: control for the new qemu-execve native passthrough --------
  _TRIAGE_FAIL_NOTE="disabling native passthrough does NOT change the crash" \
  _triage_verdict "test_unique @ QEMU_EXECVE_NATIVE_PASSTHROUGH=0" \
    "disabling native passthrough AVOIDS the crash -- the passthrough path is implicated" \
    env QEMU_EXECVE_NATIVE_PASSTHROUGH=0 ${SEGVCATCH:-} ${QEMU_EXECVE} ${PYTHON} -m unittest -v -k test_unique numba.tests.test_array_methods

  echo "DIAG: ======================== END DIAGNOSTIC BATTERY ========================"
fi

# LOCAL DIAGNOSTIC MODE. Stop here, before the expensive forefronted blocks and
# the full --random suite. CI never sets NUMBA_CF_TRIAGE, and recipe.yaml
# defaults it to "0", so CI behaviour is completely unchanged. Placing this exit
# early means nothing below needs its own opt-out.
echo "TRIAGE: NUMBA_CF_TRIAGE=${NUMBA_CF_TRIAGE:-<unset>}"
echo "TRIAGE: NUMBA_CF_RUN_SKIPPED=${NUMBA_CF_RUN_SKIPPED:-<unset>}"
if [[ "${NUMBA_CF_TRIAGE:-0}" == "1" ]]; then
  echo "TRIAGE: NUMBA_CF_TRIAGE=1 -- stopping before the full test suite"
  exit 0
fi
# --- end unresolved-skip triage block ----------------------------------------

# --- forefronted known-red tests, ALL platforms (conda-forge/numba-feedstock#203)
# Mirror of the win_64 block in run_test.bat lines 31-36, extended to every unix
# lane. Run serially and UNSAMPLED so they execute identically on every lane and
# every python version.
#
# Why this is needed: the main suite below is --random sampled, so a test absent
# from a log may simply never have been drawn. That makes it impossible to tell
# "passed", "skipped" and "not selected" apart, and impossible to characterise a
# flaky failure. Forefronting gives a deterministic per-lane signal.
#
# test_linalg_lstsq is nondeterministic by nature: numba checks infs/NaN BEFORE
# emptiness in lstsq, so the content of the uninitialized LAPACK workspace decides
# which LinAlgError surfaces for a zero-size input. Observed FAIL/PASS/FAIL on
# win_64, and recorded known-red on win_64 py3.11 and py3.14t. Running it on unix
# too establishes whether it is Windows-specific or general.
#
# ${QEMU_EXECVE} is empty on native lanes and expands away; on cross lanes it is
# the emulator. It stays UNQUOTED for exactly that reason.
echo "VERIFY: forefronted known-red tests (lstsq, charseq, recursion) -- #203"
$SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -v \
  numba.tests.test_linalg.TestLinalgLstsq.test_linalg_lstsq \
  numba.tests.test_record_dtype.TestRecordDtypeWithCharSeq.test_npm_argument_charseq \
  numba.tests.test_recursion
# --- end forefronted known-red tests -----------------------------------------

# --- bounded triage probe for test_numpy_binomial hang (conda-forge/numba-feedstock#210)
# The skip patch (skip-test_numpy_binomial-arrays-on-ppc64le.patch) has been
# removed: numba.tests.test_random.TestRandomArrays.test_numpy_binomial now
# runs in the sampled suite below like any other test.
#
# The failure is INTERMITTENT, not deterministic. On PR #210 commit
# ed8bc476, all five ppc64le lanes (cp311, cp312, cp313, cp314, cp314t) ran
# this test successfully when forced, at 20-27s compile and 24-33s execute.
# The single original timeout on cp314 has not reproduced since.
#
# This probe is KEPT even though the test is no longer skipped: the main
# suite below is --random sampled, so this test is drawn only some of the
# time, and a green log is not evidence that it ran. This probe runs it
# unsampled on every ppc64le lane, on every CI run, giving a deterministic
# per-lane record of compile and execute cost -- the data needed to
# establish the real flake rate.
#
# If the hang recurs inside the sampled suite, patches/label-known-flaky-timeouts.patch
# makes numba's parallel-runner timeout print a greppable
# "NUMBA_CF_KNOWN_FLAKY_TIMEOUT:" banner naming this test. Grep the lane log
# for that token: it means known intermittent flake, rerun the lane, it is
# not a regression.
#
# This probe is diagnostic only, MUST NOT fail the lane, and MUST be bounded --
# unbounded, this is exactly the test that has hung before and would wedge
# the whole job for the remainder of the CI timeout.
#
# Two probes discriminate compile-time cost/failure from run-time:
#   (a) COMPILE probe: force compilation of the array-producing binomial
#       specialization via .compile(), with NO execution, so zero RNG draws
#       happen.
#   (b) EXECUTE probe: actually run the test.
# Interpretation:
#   compile OK, execute TIMEOUT -> runtime infinite loop (the draw loop itself
#     never terminates under emulation)
#   compile TIMEOUT             -> codegen/compile pathology (the hang is in
#     LLVM lowering or numba's typing of this specialization, not in the
#     generated code's runtime behaviour)
if [[ "${target_platform:-}" == "linux-ppc64le" ]]; then
  echo "VERIFY: bounded triage probe for test_numpy_binomial hang -- #210"

  _t0=${SECONDS}
  set +e
  timeout 180 ${QEMU_EXECVE} ${PYTHON} -c "
import numba
import numpy as np

@numba.njit
def f():
    return np.random.binomial(20, 0.5, 8)

f.compile(())
print('COMPILE_PROBE: compiled without executing')
"
  _probe_compile_rc=$?
  set -e
  _probe_compile_elapsed=$((SECONDS - _t0))
  if [[ "${_probe_compile_rc}" -eq 124 ]]; then
    echo "TRIAGE TIMEOUT: COMPILE probe (${_probe_compile_elapsed}s) -- codegen/compile pathology, hang is in compilation not runtime"
  elif [[ "${_probe_compile_rc}" -eq 0 ]]; then
    echo "TRIAGE PASS: COMPILE probe (${_probe_compile_elapsed}s) -- compiled cleanly, zero draws executed"
  else
    echo "TRIAGE FAIL: COMPILE probe (${_probe_compile_elapsed}s) -- exited ${_probe_compile_rc}, not a timeout, inspect output above"
  fi

  _t0=${SECONDS}
  set +e
  timeout 180 $SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m unittest -v numba.tests.test_random.TestRandomArrays.test_numpy_binomial
  _probe_execute_rc=$?
  set -e
  _probe_execute_elapsed=$((SECONDS - _t0))
  if [[ "${_probe_execute_rc}" -eq 124 ]]; then
    echo "TRIAGE TIMEOUT: EXECUTE probe (${_probe_execute_elapsed}s) -- if COMPILE probe passed, this is a runtime infinite loop, not a compile pathology"
  elif [[ "${_probe_execute_rc}" -eq 0 ]]; then
    echo "TRIAGE PASS: EXECUTE probe (${_probe_execute_elapsed}s) -- test_numpy_binomial actually passed on this run"
  else
    echo "TRIAGE FAIL: EXECUTE probe (${_probe_execute_elapsed}s) -- exited ${_probe_execute_rc}, not a timeout, inspect output above"
  fi

  echo "TRIAGE: compile_rc=${_probe_compile_rc} execute_rc=${_probe_execute_rc} (124=timeout, 0=pass)"
fi
# --- end test_numpy_binomial triage probe ------------------------------------

TEST_NPROCS="${CPU_COUNT}"
FAST_TESTS="${FAST_TESTS:-0}"

# --- cross-build toolchain quick-fail (conda-forge/numba-feedstock#201) -------
# Every test listed below invokes the C or C++ toolchain at test time. These are
# precisely the tests that failed across the four ppc64le lanes of PR #201 when
# the test environment carried no build-platform compiler.
#
# They are run deterministically and UP FRONT for one reason: the suite at the
# end of this script is sampled (--random), so it draws a different member of
# this family on each run. A green sampled suite is therefore NOT evidence that
# the test-time toolchain is present. Running them here fails in minutes rather
# than after the full ~50 minute suite.
#
# test_lifetime_of_task_scheduler_handle is NOT a toolchain test, but it has
# now been characterised. On the green ppc64le py3.13 lane of run
# 33005537482 it reported: skipped "Compilation of DSO failed. Check output
# for details". The root cause is a dependency asymmetry, not an emulation
# failure: the test env resolves tbb (runtime) but tbb-devel (headers) is
# only in the BUILD env, so no TBB-linked DSO can be compiled at test time.
# It is not emulation-related: the five other tests in this block also
# invoke powerpc64le-conda-linux-gnu-cc under the same emulator and all
# passed. Confidence is MEDIUM, not high: numba's harness swallows the
# compiler stderr, so the underlying error text was never captured in the
# log. It is kept in this list so the skip stays visible; adding tbb-devel
# to the test requirements would make it actually execute.
if [[ "${target_platform:-}" == "linux-ppc64le" ]]; then
  echo "VERIFY: test-time C/C++ toolchain availability -- see conda-forge/numba-feedstock#201"
  $SEGVCATCH ${QEMU_EXECVE} ${PYTHON} -m numba.runtests -v \
    numba.tests.test_pycc.TestCC.test_compile_for_cpu \
    numba.tests.test_pycc.TestCC.test_dynamic_exc \
    numba.tests.test_pycc.TestCC.test_hashing \
    numba.tests.test_pycc.TestCC.test_reproducible_build \
    numba.tests.test_pycc.TestDistutilsSupport.test_setup_py_distutils \
    numba.tests.test_pycc.TestDistutilsSupport.test_setup_py_setuptools_nested \
    numba.tests.test_cffi.TestCFFI.test_from_buffer_numpy_multi_array \
    numba.tests.test_parallel_backend.TestTBBSpecificIssues.test_lifetime_of_task_scheduler_handle
fi
# --- end toolchain quick-fail ------------------------------------------------

# Check test discovery works
${QEMU_EXECVE} ${PYTHON} -m numba.tests.test_runtests

# Disable NumPy AVX512_SKX dispatch when it is dispatchable and NumPy >= 1.22
# (avoids low-accuracy SVML libm replacements in ufunc loops).
_NPY_CMD='from numba.misc import numba_sysinfo;\
          sysinfo=numba_sysinfo.get_sysinfo();\
          print("AVX512_SKX" in sysinfo.get("NumPy Supported SIMD dispatch", ()) and
                sysinfo.get("NumPy Version", "0")>="1.22")'
if [[ "$(${QEMU_EXECVE} ${PYTHON} -c "$_NPY_CMD")" == "True" ]]; then
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
