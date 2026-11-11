#!/usr/bin/env bash
# =============================================================================
# validate_lab.sh — Annual pre-course validation of the "Lab - RNAseq" (mouse chr19)
# =============================================================================
# Instructor-operated wrapper that:
#   1. detects Conda and initializes its Bash shell integration,
#   2. checks whether Mamba is installed and functional, and installs it
#      into base ONLY when it is missing (never updates all of base,
#      never removes mamba or base),
#   3. creates a uniquely named temporary Conda environment from
#      environment.yml (strict channel priority via CLI flag only —
#      no persistent .condarc changes; the YAML's `name: rnaseq_lab` is
#      overridden by -n, so the file stays usable by students),
#   4. activates that exact environment, isolates R, and verifies that the
#      scientific tools resolve inside the temporary environment (not base).
#      A pre-existing environment named `rnaseq_lab` is never used,
#   5. runs the previously validated scientific validator (44 checks) —
#      embedded VERBATIM in this file below the "SCIENTIFIC VALIDATOR"
#      marker. It is extracted at runtime to $LOGS/scientific_validator.sh
#      and executed as a subprocess, so its own exit-code handling,
#      reporting logic and `finish` work exactly as validated on the server,
#   6. persists all evidence (conda/mamba versions, solver, environment
#      creation/removal logs and exit codes, package manifests, resolved
#      environment, tool versions, R package versions, full scientific run
#      output, report summary, cleanup outcome) in the timestamped run
#      directory, OUTSIDE the temporary conda environment,
#   7. deactivates and removes ONLY the environment created by this
#      execution (KEEP_ENV=1 keeps it for debugging and reports its name).
#
# Usage:
#   bash validate_lab.sh
#   KEEP_ENV=1 bash validate_lab.sh        # keep the temporary env afterwards
#   # in the background (survives a dropped SSH connection):
#   nohup bash validate_lab.sh > run.out 2>&1 &
#   tail --pid=$! -f run.out
#
# Optional environment variables:
#   ROOT=/path        run directory (default: ~/rnaseq_validation_<timestamp>)
#   THREADS=4         threads for HISAT2 / featureCounts (the lab uses 1)
#   SKIP_ANNOT=1      skip the bonus part (goseq / Reactome)
#   KEEP_ENV=1        do NOT remove the temporary conda environment at the end
#
# Run directory layout (outside the temporary conda environment):
#   rnaseq/             the lab folder, as the student would see it
#   logs/               one log per step, plus scientific_validator.sh
#                       (the extracted copy of the embedded scientific
#                       validator) and scientific run output
#   reference_outputs/  reference files downloaded for comparisons
#   evidence/           bootstrap + environment + software evidence:
#                         run_info.txt            start/end info, exit codes,
#                                                 whether base was modified
#                         conda_version.txt       conda --version
#                         conda_hook.txt          generated 'conda shell.bash hook'
#                         conda_hook.err          stderr from hook generation
#                         conda_solver.txt        conda base + selected solver
#                         mamba_version.txt       mamba --version
#                         mamba_install.log       only if mamba was installed
#                         env_name_prefix.txt     temporary env name + prefix
#                         env_create.log          mamba env create output
#                         env_create_exit.txt     creation exit code
#                         env_activate.log        conda activate output
#                         tool_paths.txt          where each tool resolved
#                         tool_versions.txt       active tool versions
#                         conda_list.txt          conda list
#                         conda_list_explicit.txt conda list --explicit
#                         conda_env_export.yml    resolved environment YAML
#                         environment.yml         copy of the requested spec
#                         scientific_run.log      full scientific run output
#                         report_summary.txt      PASS/WARN/FAIL/SKIP counts
#                         r_package_versions.txt  R package versions
#                         env_remove.log          conda env remove output
#                         cleanup_result.txt      cleanup outcome
#   REPORT.txt          the final scientific validation report
#
# Exit codes:
#   0    success (0 FAIL, no unexpected SKIP, cleanup OK)
#   10   Conda not found / shell integration failed
#   11   Mamba installation into base failed
#   12   temporary environment creation failed (or name collision,
#        or environment.yml missing)
#   13   environment activation / verification failed
#   14   scientific validation failed (FAIL present, unexpected SKIP,
#        or the scientific run did not complete)
#   15   cleanup of the temporary environment failed, or was refused
#        because the environment could not be positively verified
#   130  interrupted by a signal (cleanup still runs)
#
# Design notes:
#   - No `set -e`: the scientific validator deliberately captures command
#     exit codes (its run() helper) and reports PASS/WARN/FAIL/SKIP; a
#     global errexit would break that behaviour.
#   - The scientific part runs in a subprocess, so its `finish`/`exit`
#     logic is untouched and its variables cannot collide with the wrapper.
#   - Cleanup removes an environment ONLY after positive verification:
#     the name must be exactly the one generated by this run, a prefix
#     must have been recorded at creation/activation, the prefix basename
#     must equal the name, the prefix must differ from conda base, and
#     `conda info -e` must list that exact name at that exact prefix.
#     If any check fails the environment is LEFT UNTOUCHED and manual
#     investigation is reported (exit 15). No wildcards, no rm -rf, no
#     removal of base or of pre-existing environments (e.g. `rnaseq_lab`).
#   - A cleanup failure is reported separately and never hides the
#     original scientific/bootstrap failure code.
# =============================================================================

export LC_ALL=C
shopt -s nullglob

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
ENV_YML="$SCRIPT_DIR/environment.yml"

KEEP_ENV="${KEEP_ENV:-0}"
THREADS="${THREADS:-4}"
SKIP_ANNOT="${SKIP_ANNOT:-0}"

STAMP="$(date +%Y%m%d_%H%M%S)"
ROOT="${ROOT:-$HOME/rnaseq_validation_$STAMP}"
LOGS="$ROOT/logs"
EV="$ROOT/evidence"

# Exit codes
RC_OK=0
RC_CONDA=10
RC_MAMBA=11
RC_CREATE=12
RC_ACTIVATE=13
RC_SCIENCE=14
RC_CLEANUP=15

FINAL_RC=""           # first fatal failure code, if any
CLEANUP_RC=""         # set to RC_CLEANUP if the cleanup fails
ENV_OWNED_BY_US=0     # 1 only once this run created (or partially created) the env
TMP_ENV=""
ENV_PREFIX=""
BASE_PREFIX=""
PRE_ACTIVE_ENV="${CONDA_DEFAULT_ENV:-none}"
CLEANUP_DONE=0
T_START=$SECONDS

if ! mkdir -p "$LOGS" "$EV" "$ROOT/reference_outputs"; then
  echo "❌ FATAL: cannot create the run directory: $ROOT" >&2
  exit 1
fi

# Append a key: value line to the run info file (safe for annual comparisons)
info() { printf '%s\n' "$1" >> "$EV/run_info.txt"; }

{
  echo "# run_info - annual RNA-seq lab validation"
  echo "started_utc: $(date -u '+%Y-%m-%d %H:%M:%S')"
  echo "started_local: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "hostname: $(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)"
  echo "user: ${USER:-unknown}"
  echo "script: $SCRIPT_DIR/validate_lab.sh"
  echo "run_dir: $ROOT"
  echo "keep_env: $KEEP_ENV"
  echo "threads: $THREADS"
  echo "skip_annot: $SKIP_ANNOT"
  echo "pre_existing_active_env: $PRE_ACTIVE_ENV"
  echo "environment_yaml: $ENV_YML"
} > "$EV/run_info.txt"

echo "======================================================================="
echo "🚀 Annual RNA-seq lab validation (wrapper)"
echo "📂 Run directory: $ROOT"
echo "======================================================================="

# =============================================================================
# Cleanup (runs on every exit path: normal, fatal failure, or signal)
# =============================================================================
on_signal() {
  echo
  echo "⚠️  Interrupted (signal: $1). Preserving logs; cleaning up before exiting..." >&2
  if [ -z "$FINAL_RC" ]; then FINAL_RC=130; fi
  exit "$FINAL_RC"
}
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

do_cleanup() {
  [ "$CLEANUP_DONE" = "1" ] && return 0
  CLEANUP_DONE=1
  local logf="$EV/cleanup_result.txt" rc=0 cur expected_name why

  {
    echo "# cleanup result - annual RNA-seq lab validation"
    echo "finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "keep_env: $KEEP_ENV"
    echo "env_name: ${TMP_ENV:-<none>}"
    echo "env_prefix: ${ENV_PREFIX:-<none>}"
    echo "env_owned_by_this_run: $ENV_OWNED_BY_US"
  } > "$logf"

  if [ "$ENV_OWNED_BY_US" != "1" ] || [ -z "$TMP_ENV" ]; then
    echo "action: none (no conda environment was created by this run)" >> "$logf"
    info "cleanup: no environment to remove (nothing created by this run)"
    return 0
  fi

  # 1) Deactivate the temporary env if it is still active.
  if [ "${CONDA_DEFAULT_ENV:-}" = "$TMP_ENV" ]; then
    if conda deactivate >>"$logf" 2>&1; then
      echo "deactivate: OK" >> "$logf"
    else
      echo "deactivate: FAILED" >> "$logf"
    fi
  fi

  # 2) KEEP_ENV=1: retain the environment for debugging and report it.
  if [ "$KEEP_ENV" = "1" ]; then
    echo "action: KEPT (KEEP_ENV=1) -> $TMP_ENV ($ENV_PREFIX)" >> "$logf"
    echo "🔎 KEEP_ENV=1 -> temporary environment KEPT: $TMP_ENV ($ENV_PREFIX)"
    info "cleanup: kept $TMP_ENV (KEEP_ENV=1)"
    return 0
  fi

  # 3) POSITIVE verification before any removal. Every condition below must
  #    hold; otherwise the environment is left untouched and manual
  #    investigation is reported. This prevents removing anything that is
  #    not provably this run's environment.
  expected_name="rnaseq_lab_${STAMP}_$$"
  why=""
  if [ "$TMP_ENV" != "$expected_name" ]; then
    why="name '$TMP_ENV' is not the name generated by this run ('$expected_name')"
  fi
  if [ -z "$ENV_PREFIX" ]; then
    why="${why:+$why; }no env prefix was recorded (cannot prove which prefix belongs to this run)"
  fi
  if [ -n "$ENV_PREFIX" ] && [ "$(basename -- "$ENV_PREFIX")" != "$TMP_ENV" ]; then
    why="${why:+$why; }prefix '$ENV_PREFIX' does not end with the environment name"
  fi
  if [ -n "$ENV_PREFIX" ] && [ -n "$BASE_PREFIX" ] && [ "$ENV_PREFIX" = "$BASE_PREFIX" ]; then
    why="${why:+$why; }prefix equals the conda base installation"
  fi
  if [ "${CONDA_DEFAULT_ENV:-}" = "$TMP_ENV" ]; then
    why="${why:+$why; }environment is still active (deactivation failed)"
  fi
  cur="$(conda info -e 2>/dev/null | awk -v e="$TMP_ENV" '$1==e{if($2=="*"){print $3}else{print $2}}')"
  if [ -z "$cur" ]; then
    why="${why:+$why; }'conda info -e' does not list '$TMP_ENV'"
  elif [ -n "$ENV_PREFIX" ] && [ "$cur" != "$ENV_PREFIX" ]; then
    why="${why:+$why; }'conda info -e' lists it at '$cur', not at the recorded prefix '$ENV_PREFIX'"
  fi
  if [ -n "$why" ]; then
    echo "action: REFUSED - $why" >> "$logf"
    echo "❌ CLEANUP NOT PERFORMED: could not positively verify '$TMP_ENV'." >&2
    echo "   Reason: $why" >&2
    echo "   The environment was LEFT UNTOUCHED - manual investigation required:" >&2
    echo "     conda env list" >&2
    echo "     # only if it is really this run's leftover:" >&2
    echo "     conda env remove -n '$TMP_ENV' --yes" >&2
    info "cleanup: REFUSED ($why) - environment left untouched, manual investigation required"
    CLEANUP_RC=$RC_CLEANUP
    return 0
  fi

  # 4) Remove ONLY this run's environment (exact name, no wildcards).
  if conda env remove -n "$TMP_ENV" --yes > "$EV/env_remove.log" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  cur="$(conda info -e 2>/dev/null | awk -v e="$TMP_ENV" '$1==e{print $2}')"
  if [ $rc -eq 0 ] && [ -z "$cur" ]; then
    echo "action: REMOVED $TMP_ENV (exit=0, verified absent from 'conda info -e')" >> "$logf"
    echo "✅ Temporary environment removed: $TMP_ENV"
    info "cleanup: removed $TMP_ENV"
  else
    echo "action: FAILED (remove exit=$rc, still listed: '${cur:-no}'); log: $EV/env_remove.log" >> "$logf"
    echo "❌ CLEANUP FAILED: could not remove '$TMP_ENV' (exit=$rc)." >&2
    echo "   Manual removal: conda env remove -n '$TMP_ENV' --yes" >&2
    info "cleanup: FAILED (remove exit=$rc)"
    CLEANUP_RC=$RC_CLEANUP
  fi
  return 0
}

on_exit() {
  local orig_rc=$? out
  if [ -z "$FINAL_RC" ]; then FINAL_RC=$orig_rc; fi
  do_cleanup
  {
    echo "finished_utc: $(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "total_duration_seconds: $((SECONDS - T_START))"
  } >> "$EV/run_info.txt"
  # FINAL_RC=0 means success; only a NON-ZERO code counts as a failure.
  if [ -n "$CLEANUP_RC" ] && [ "${FINAL_RC:-0}" -ne 0 ]; then
    # Both failed: preserve the original failure code and report cleanup
    # separately (the cleanup failure never masks the original one).
    out=$FINAL_RC
    echo
    echo "⚠️  The original failure (exit $FINAL_RC) is reported as the exit code;" >&2
    echo "⚠️  environment cleanup also failed (exit $CLEANUP_RC) - see $EV/cleanup_result.txt" >&2
  elif [ -n "$CLEANUP_RC" ]; then
    # Everything else succeeded, but the temporary environment could not be
    # removed (or was refused for safety): report that with its own code.
    out=$CLEANUP_RC
    echo
    echo "⚠️  Validation succeeded, but environment cleanup failed (exit $CLEANUP_RC) - see $EV/cleanup_result.txt" >&2
  else
    out=$FINAL_RC
  fi
  info "final_exit_code: $out"
  echo
  echo "======================================================================="
  echo "📂 Run directory (pipeline outputs + evidence preserved): $ROOT"
  echo "   Scientific report: $ROOT/REPORT.txt"
  echo "   Step logs:         $LOGS"
  echo "   Evidence:          $EV"
  echo "======================================================================="
  exit "$out"
}
trap on_exit EXIT

# =============================================================================
# PHASE 1 — Conda detection and Bash shell integration
# =============================================================================
echo; echo "━━ PHASE 1: conda detection and initialization ━━"
CONDA_BIN=""
if command -v conda >/dev/null 2>&1; then
  CONDA_BIN="$(command -v conda)"
else
  # Non-interactive shells may not have conda on PATH: try standard locations.
  for c in "$HOME/miniconda3/bin/conda" "$HOME/anaconda3/bin/conda" \
           "$HOME/miniforge3/bin/conda" "$HOME/mambaforge/bin/conda" \
           /opt/miniconda3/bin/conda /opt/anaconda3/bin/conda; do
    if [ -x "$c" ]; then
      CONDA_BIN="$c"
      export PATH="$(dirname -- "$c"):$PATH"
      break
    fi
  done
fi
if [ -z "$CONDA_BIN" ]; then
  echo "❌ FATAL: conda not found on PATH or in the standard locations." >&2
  echo "   Install Conda, or run this script from a shell where conda is on PATH." >&2
  info "fatal: conda not found (exit $RC_CONDA)"
  exit $RC_CONDA
fi
echo "   conda: $CONDA_BIN"

# Generate the shell hook and evaluate it as two separately validated steps:
# (1) generation must succeed and produce content, (2) evaluation must succeed
# and actually define the `conda` shell function.
CONDA_HOOK="$(conda shell.bash hook 2> "$EV/conda_hook.err")"
HOOK_RC=$?
printf '%s\n' "$CONDA_HOOK" > "$EV/conda_hook.txt"
if [ $HOOK_RC -ne 0 ]; then
  echo "❌ FATAL: generating the conda shell hook failed (exit=$HOOK_RC)." >&2
  echo "   stderr: $EV/conda_hook.err (last lines)" >&2
  tail -n 8 "$EV/conda_hook.err" 2>/dev/null | sed 's/^/   | /' >&2
  info "fatal: conda shell hook generation failed (exit=$HOOK_RC, exit code $RC_CONDA)"
  exit $RC_CONDA
fi
if [ -z "$CONDA_HOOK" ]; then
  echo "❌ FATAL: 'conda shell.bash hook' produced no output (Bash shell integration unavailable)." >&2
  info "fatal: conda shell hook was empty (exit code $RC_CONDA)"
  exit $RC_CONDA
fi
if ! eval "$CONDA_HOOK"; then
  echo "❌ FATAL: evaluating the generated conda shell hook failed." >&2
  echo "   Hook text: $EV/conda_hook.txt" >&2
  info "fatal: conda shell hook evaluation failed (exit code $RC_CONDA)"
  exit $RC_CONDA
fi
if ! declare -F conda >/dev/null 2>&1; then
  echo "❌ FATAL: after evaluating the hook, the 'conda' shell function is not defined." >&2
  echo "   Hook text: $EV/conda_hook.txt" >&2
  info "fatal: conda shell function missing after hook (exit code $RC_CONDA)"
  exit $RC_CONDA
fi
info "conda_shell_hook: generated and evaluated OK"
BASE_PREFIX="$(conda info --base 2>/dev/null | tail -1)"
conda --version > "$EV/conda_version.txt" 2>&1
{
  echo "# conda base"
  echo "$BASE_PREFIX"
  echo "# selected conda solver (as configured; mamba uses the libmamba solver)"
  conda config --show solver 2>&1
} > "$EV/conda_solver.txt"
info "conda_bin: $CONDA_BIN"
info "conda_version: $(tr -d '\n' < "$EV/conda_version.txt")"
info "conda_base: $BASE_PREFIX"
info "conda_solver: $(grep -v '^#' "$EV/conda_solver.txt" | head -1)"
# Informational only: this run never uses or modifies a pre-existing
# environment named `rnaseq_lab`; it always creates its own temporary one.
if conda info -e 2>/dev/null | awk '{print $1}' | grep -qx 'rnaseq_lab'; then
  info "note: a pre-existing env named 'rnaseq_lab' exists on this account; it is NOT used by this run"
fi

# =============================================================================
# PHASE 2 — Mamba detection (conditional installation into base)
# =============================================================================
echo; echo "━━ PHASE 2: mamba detection (conditional install) ━━"
MAMBA_WAS_PRESENT=0
if command -v mamba >/dev/null 2>&1 && mamba --version >/dev/null 2>&1; then
  MAMBA_WAS_PRESENT=1
  echo "   mamba already present and functional: $(command -v mamba)"
else
  echo "   mamba NOT found or not functional -> installing into base (only adds mamba):"
  echo "   conda install -n base -c conda-forge mamba -y"
  if conda install -n base -c conda-forge mamba -y > "$EV/mamba_install.log" 2>&1 \
     && command -v mamba >/dev/null 2>&1 && mamba --version >/dev/null 2>&1; then
    echo "   mamba installed successfully."
  else
    echo "❌ FATAL: mamba installation into base failed." >&2
    echo "   Log: $EV/mamba_install.log (last lines)" >&2
    tail -n 8 "$EV/mamba_install.log" 2>/dev/null | sed 's/^/   | /'
    info "mamba_was_present_before_run: no"
    info "bootstrap_modified_base: yes (mamba installation attempted; FAILED)"
    info "fatal: mamba installation failed (exit $RC_MAMBA)"
    exit $RC_MAMBA
  fi
fi
mamba --version > "$EV/mamba_version.txt" 2>&1
if [ "$MAMBA_WAS_PRESENT" = "1" ]; then
  info "mamba_was_present_before_run: yes"
  info "bootstrap_modified_base: no"
else
  info "mamba_was_present_before_run: no"
  info "bootstrap_modified_base: yes (installed mamba into base via 'conda install -n base -c conda-forge mamba -y')"
fi
info "mamba_version: $(tr -d '\n' < "$EV/mamba_version.txt")"

# =============================================================================
# PHASE 3 — Temporary environment: unique name + creation via Mamba
# =============================================================================
echo; echo "━━ PHASE 3: temporary conda environment ━━"
if [ ! -s "$ENV_YML" ]; then
  echo "❌ FATAL: environment.yml is missing or empty: $ENV_YML" >&2
  info "fatal: environment.yml missing (exit $RC_CREATE)"
  exit $RC_CREATE
fi
TMP_ENV="rnaseq_lab_${STAMP}_$$"
if ! [[ "$TMP_ENV" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,99}$ ]]; then
  echo "❌ FATAL: generated environment name failed validation: $TMP_ENV" >&2
  info "fatal: invalid generated env name (exit $RC_CREATE)"
  exit $RC_CREATE
fi
if conda info -e 2>/dev/null | awk '{print $1}' | grep -qx "$TMP_ENV"; then
  echo "❌ FATAL: environment '$TMP_ENV' already exists; refusing to reuse or overwrite it." >&2
  info "fatal: env name collision (exit $RC_CREATE)"
  exit $RC_CREATE
fi
echo "   temporary environment: $TMP_ENV"
mamba env create -f "$ENV_YML" -n "$TMP_ENV" --strict-channel-priority --yes \
  > "$EV/env_create.log" 2>&1
CREATE_RC=$?
printf '%s\n' "$CREATE_RC" > "$EV/env_create_exit.txt"
info "env_name: $TMP_ENV"
info "env_create_exit: $CREATE_RC"
if [ $CREATE_RC -ne 0 ]; then
  echo "❌ FATAL: temporary environment creation failed (exit=$CREATE_RC)." >&2
  echo "   Log: $EV/env_create.log (last lines)" >&2
  tail -n 8 "$EV/env_create.log" 2>/dev/null | sed 's/^/   | /'
  # A partially created environment carrying this unique (timestamp+PID)
  # name still belongs to this run; cleanup is allowed to remove it.
  if conda info -e 2>/dev/null | awk '{print $1}' | grep -qx "$TMP_ENV"; then
    ENV_OWNED_BY_US=1
    ENV_PREFIX="$(conda info -e 2>/dev/null | awk -v e="$TMP_ENV" '$1==e{if($2=="*"){print $3}else{print $2}}')"
    info "env_prefix: ${ENV_PREFIX:-unknown} (partial creation)"
  fi
  exit $RC_CREATE
fi
ENV_OWNED_BY_US=1
# Record the exact prefix now, while the environment is known to be ours:
# if activation later fails, cleanup can still positively verify and remove
# precisely this environment (or refuse if verification fails).
ENV_PREFIX="$(conda info -e 2>/dev/null | awk -v e="$TMP_ENV" '$1==e{if($2=="*"){print $3}else{print $2}}')"
info "env_prefix: ${ENV_PREFIX:-unknown} (recorded after creation)"
echo "   environment created successfully (log: $EV/env_create.log)"

# =============================================================================
# PHASE 4 — Activation, R isolation, tool path verification
# =============================================================================
echo; echo "━━ PHASE 4: activation and verification ━━"
if ! conda activate "$TMP_ENV" > "$EV/env_activate.log" 2>&1; then
  echo "❌ FATAL: 'conda activate $TMP_ENV' failed." >&2
  echo "   Log: $EV/env_activate.log (last lines)" >&2
  tail -n 8 "$EV/env_activate.log" 2>/dev/null | sed 's/^/   | /'
  info "fatal: activation failed (exit $RC_ACTIVATE)"
  exit $RC_ACTIVATE
fi
if [ "${CONDA_DEFAULT_ENV:-}" != "$TMP_ENV" ]; then
  echo "❌ FATAL: activation did not take effect: CONDA_DEFAULT_ENV='${CONDA_DEFAULT_ENV:-}' (expected '$TMP_ENV')." >&2
  info "fatal: CONDA_DEFAULT_ENV mismatch (exit $RC_ACTIVATE)"
  exit $RC_ACTIVATE
fi
ENV_PREFIX="${CONDA_PREFIX:-}"
if [ -z "$ENV_PREFIX" ] || [ "$(basename -- "$ENV_PREFIX")" != "$TMP_ENV" ] || [ "$ENV_PREFIX" = "$BASE_PREFIX" ]; then
  echo "❌ FATAL: CONDA_PREFIX '$ENV_PREFIX' is not the temporary environment '$TMP_ENV'." >&2
  info "fatal: CONDA_PREFIX mismatch (exit $RC_ACTIVATE)"
  exit $RC_ACTIVATE
fi
info "env_prefix: $ENV_PREFIX"
echo "   active environment: $TMP_ENV ($ENV_PREFIX)"

# R library isolation (verified on the server):
unset R_HOME
export R_LIBS_USER=""
export R_LIBS_SITE=""
echo "   R isolated (R_HOME unset, R_LIBS_USER and R_LIBS_SITE emptied)"

# The scientific tools must resolve inside the temporary env, not in base.
tool_fail=0
: > "$EV/tool_paths.txt"
for t in hisat2 hisat2-build samtools featureCounts fastqc multiqc Rscript; do
  p="$(command -v "$t" 2>/dev/null || true)"
  case "$p" in
    "")                       st="FAIL: not found"; tool_fail=1 ;;
    "$ENV_PREFIX"/*)          st="OK: inside the temporary environment" ;;
    "$BASE_PREFIX"/*)         st="FAIL: resolves to base"; tool_fail=1 ;;
    *)                        st="FAIL: unexpected location"; tool_fail=1 ;;
  esac
  printf '%-14s %s  [%s]\n' "$t" "${p:-<not found>}" "$st" | tee -a "$EV/tool_paths.txt"
done
if [ $tool_fail -ne 0 ]; then
  echo "❌ FATAL: one or more scientific tools do not resolve inside '$TMP_ENV'." >&2
  echo "   See: $EV/tool_paths.txt" >&2
  info "fatal: tool path verification failed (exit $RC_ACTIVATE)"
  exit $RC_ACTIVATE
fi

# =============================================================================
# PHASE 5 — Evidence snapshots (while the environment is active)
# =============================================================================
echo; echo "━━ PHASE 5: evidence snapshots ━━"
{
  echo "hisat2: $(hisat2 --version 2>&1 | head -1 | awk '{print $NF}')"
  echo "samtools: $(samtools --version 2>&1 | head -1)"
  echo "featureCounts: $(featureCounts -v 2>&1 | grep -i featureCounts | head -1 | xargs)"
  echo "fastqc: $(fastqc --version 2>&1 | head -1)"
  echo "multiqc: $(multiqc --version 2>&1 | head -1)"
  echo "R: $(R --version 2>&1 | grep -m1 '^R version' | cut -d' ' -f1-3)"
  echo "python: $(python --version 2>&1 || true)"
} > "$EV/tool_versions.txt" 2>&1
conda list -n "$TMP_ENV" > "$EV/conda_list.txt" 2>&1
conda list --explicit -n "$TMP_ENV" > "$EV/conda_list_explicit.txt" 2>&1
mamba env export -n "$TMP_ENV" > "$EV/conda_env_export.yml" 2>&1
cp "$ENV_YML" "$EV/environment.yml"
{
  echo "env_name: $TMP_ENV"
  echo "env_prefix: $ENV_PREFIX"
} > "$EV/env_name_prefix.txt"
echo "   evidence written to $EV"

# =============================================================================
# PHASE 6 — Run the scientific validator (44 checks)
# =============================================================================
echo; echo "━━ PHASE 6: scientific validation (44 checks) ━━"
SCI="$LOGS/scientific_validator.sh"
# The scientific validator is embedded verbatim in this file (between the
# SCIENTIFIC VALIDATOR markers below). It is extracted here and executed as
# a subprocess so that its exit-code handling, PASS/WARN/FAIL/SKIP reporting
# and `finish` logic work exactly as validated (44 PASS on the server).
cat > "$SCI" <<'SCIENTIFIC_VALIDATOR_EOF'
#!/usr/bin/env bash
# =============================================================================
# validate_lab.sh  -  End-to-end validation of the "Lab - RNAseq" (mouse chr19)
# =============================================================================
# Reproduces the RNA-seq workflow using compatible tool commands and,
# after every step, checks the RESULTS and not just the exit
# code: read counts of the fastq files, alignment rates, featureCounts assigned
# %, number of MultiQC reports, agreement of the DE genes with the reference
# files, muscle GO terms, PNG sizes, etc.
#
# Usage:
#   bash validate_lab.sh
#   # in the background (survives a dropped SSH connection):
#   nohup bash validate_lab.sh > run.out 2>&1 &
#   tail --pid=$! -f run.out        # follows the log and exits when the run ends
#
# Optional environment variables:
#   ENV_NAME=rnaseq_lab     conda environment to activate
#   THREADS=4               threads for HISAT2 / featureCounts
#   ROOT=/path/to/output    optional working directory (default: timestamped in HOME)
#   SKIP_ANNOT=1            skip the bonus part (goseq / Reactome)
#
# Output: ~/rnaseq_validation_<timestamp>/
#           rnaseq/             working pipeline folder
#           logs/               one log per step
#           reference_outputs/  reference files downloaded for comparisons
#           REPORT.txt          the final report
# Exit code: 0 = no FAIL, 1 = at least one FAIL
# =============================================================================

export LC_ALL=C
shopt -s nullglob

ENV_NAME="${ENV_NAME:-rnaseq_lab}"
THREADS="${THREADS:-4}"
SKIP_ANNOT="${SKIP_ANNOT:-0}"
ROOT="${ROOT:-$HOME/rnaseq_validation_$(date +%Y%m%d_%H%M%S)}"
LAB="$ROOT/rnaseq"
LOGS="$ROOT/logs"
REFOUT="$ROOT/reference_outputs"
T_START=$SECONDS

# Dataset and reference URLs (independent of any HTML page)
URL_DATA="https://github.com/Nilsson-D/dummy_data/raw/refs/heads/main/RNA-seq/data"
URL_RAW="https://raw.githubusercontent.com/Nilsson-D/dummy_data/refs/heads/main/RNA-seq"
URL_ENS="https://ftp.ensembl.org/pub/release-99"
SAMPLES=(SRR3222409 SRR3222410 SRR3222411 SRR3222412 SRR3222413 SRR3222414)

# Baseline values for dataset validation (SRR3222409: 156992 pairs, 98.10% overall)
EXP_S1_PAIRS=156992
EXP_S1_RATE=98.10
EXP_CHR19_LEN=61431566

mkdir -p "$LOGS" "$REFOUT"

# -----------------------------------------------------------------------------
# Helpers
# NOTE: result arrays are prefixed with R_ on purpose. Conda environments export
# variables such as NM, AR, AS, LD... and a plain array called NM would collide.
# -----------------------------------------------------------------------------
nP=0; nF=0; nW=0; nS=0
R_ICON=(); R_NAME=(); R_INFO=(); TIMES=()

add() {  # add STATUS "check name" "evidence"
  local st=$1 name=$2 info=${3:-} ic
  case $st in
    PASS) nP=$((nP+1)); ic="✅";;
    FAIL) nF=$((nF+1)); ic="❌";;
    WARN) nW=$((nW+1)); ic="⚠️ ";;
    *)    nS=$((nS+1)); ic="⏭️ ";;
  esac
  R_ICON+=("$ic"); R_NAME+=("$name"); R_INFO+=("$info")
  printf '   %s %s%s\n' "$ic" "$name" "${info:+  ->  $info}"
}

run() {  # run "label" logfile command...   (saves log + elapsed time)
  local label=$1 log=$2; shift 2
  printf '\n▶ %s ...\n' "$label"
  local t0=$SECONDS
  "$@" >"$log" 2>&1
  local rc=$?
  local dt=$((SECONDS - t0))
  TIMES+=("$(printf '%-48s %5ss   exit=%s' "$label" "$dt" "$rc")")
  if [ $rc -ne 0 ]; then
    echo "   (exit code $rc - last lines of $log)"
    tail -n 8 "$log" | sed 's/^/   | /'
  fi
  return $rc
}

in_dir() { local d=$1; shift; ( cd "$LAB/$d" && "$@" ); }

need() {  # need "check name" file...   -> SKIP if an input is missing
  local n=$1; shift; local f
  for f in "$@"; do
    [ -s "$f" ] || { add SKIP "$n" "missing $(basename "$f") (an earlier step failed)"; return 1; }
  done
  return 0
}

fge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }   # a >= b
flt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 <  b+0)}'; }   # a <  b
kv()  { grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-; }       # kv file KEY

print_report() {
  echo
  echo "======================================================================="
  echo "📊  VALIDATION REPORT - RNA-seq Lab"
  echo "======================================================================="
  local i
  for i in "${!R_NAME[@]}"; do
    printf '%s %s\n' "${R_ICON[$i]}" "${R_NAME[$i]}"
    [ -n "${R_INFO[$i]}" ] && printf '      %s\n' "${R_INFO[$i]}"
  done
  echo
  echo "-----------------------------------------------------------------------"
  echo "Time per step:"
  printf '   %s\n' "${TIMES[@]}"
  echo "-----------------------------------------------------------------------"
  printf '✅ PASS: %d   ⚠️  WARN: %d   ❌ FAIL: %d   ⏭️  SKIP: %d   (total time: %dm%02ds)\n' \
    $nP $nW $nF $nS $(( (SECONDS-T_START)/60 )) $(( (SECONDS-T_START)%60 ))
  echo "Detailed logs: $LOGS"
  echo "Lab folder:    $LAB"
  echo "======================================================================="
  if [ $nF -eq 0 ] && [ $nS -eq 0 ]; then
    echo "🎉 LAB OK: all result checks passed."
    [ $nW -gt 0 ] && echo "   (still read the ⚠️  items above: not blocking, but worth a look)"
  elif [ $nF -eq 0 ]; then
    echo "🟡 No FAIL, but some checks were skipped: see the ⏭️  items."
  else
    echo "🚨 LAB NOT READY: there are ❌ items - see the log indicated for each one."
  fi
}

finish() { print_report | tee "$ROOT/REPORT.txt"; [ $nF -eq 0 ]; exit $?; }

# -----------------------------------------------------------------------------
# Helper R scripts (used ONLY for the checks, they are NOT part of the lab)
# -----------------------------------------------------------------------------
cat > "$LOGS/chk_pkgs.R" <<'EOF'
pk <- c("edgeR","DESeq2","goseq","GO.db","reactome.db","org.Mm.eg.db",
        "tidyverse","pheatmap","EnsDb.Mmusculus.v79","geneLenDataBase")
ok <- vapply(pk, function(p) nzchar(system.file(package = p)), logical(1))
cat("MISSING=", paste(pk[!ok], collapse = ","), "\n", sep = "")
v <- vapply(pk[ok], function(p) as.character(packageVersion(p)), "")
cat("VERSIONS=", paste(names(v), v, collapse = "; "), "\n", sep = "")
EOF

cat > "$LOGS/chk_counts.R" <<'EOF'
# compares counts.txt (chr19, generated here) with counts_full.txt (lab backup, whole genome)
a <- commandArgs(TRUE)
rd <- function(f) read.delim(f, skip = 1, check.names = FALSE)
x <- rd(a[1]); y <- rd(a[2])
mk <- function(d) { m <- as.matrix(d[, -(1:6)])
  colnames(m) <- sub(".*(SRR[0-9]+).*", "\\1", colnames(m)); rownames(m) <- d$Geneid; m }
cx <- mk(x); cy <- mk(y)
cat("SAMPLES=", paste(colnames(cx), collapse = ","), "\n", sep = "")
cat("NSAMPLES=", ncol(cx), "\n", sep = "")
cat("NGENES_X=", nrow(cx), "\nNGENES_Y=", nrow(cy), "\n", sep = "")
cat("IDS_IDENTICAL=", identical(sort(rownames(cx)), sort(rownames(cy))), "\n", sep = "")
is19 <- grepl("^19(;19)*$", x$Chr)
cat("N_CHR19_GENES=", sum(is19), "\n", sep = "")
cat("COUNTS_OFF_CHR19=", sum(cx[!is19, , drop = FALSE]), "\n", sep = "")
cat("COUNTS_ON_CHR19=", sum(cx[is19, , drop = FALSE]), "\n", sep = "")
keep <- intersect(x$Geneid[is19], rownames(cy))
cx2 <- cx[keep, , drop = FALSE]; cy2 <- cy[keep, colnames(cx), drop = FALSE]
act <- rowSums(cx2) > 0 | rowSums(cy2) > 0
rho <- cor(cx2[act, ], cy2[act, ], method = "spearman")
best <- colnames(rho)[apply(rho, 1, which.max)]
cat("RHO_DIAG=", paste(sprintf("%.3f", diag(rho)), collapse = ","), "\n", sep = "")
cat("RHO_DIAG_MIN=", sprintf("%.3f", min(diag(rho))), "\n", sep = "")
cat("BEST_MATCH_OK=", all(best == rownames(rho)), "\n", sep = "")
EOF

cat > "$LOGS/chk_dge.R" <<'EOF'
# compares the freshly generated dge_results_full.txt with the reference one
a <- commandArgs(TRUE)
n <- read.delim(a[1]); r <- read.delim(a[2])
cnt <- function(d) c(sig  = sum(d$padj < 0.05, na.rm = TRUE),
                     up   = sum(d$padj < 0.05 & d$log2FoldChange >  0.5, na.rm = TRUE),
                     down = sum(d$padj < 0.05 & d$log2FoldChange < -0.5, na.rm = TRUE))
cn <- cnt(n); cr <- cnt(r)
cat("N_NEW=", nrow(n), "\nN_REF=", nrow(r), "\n", sep = "")
cat("IDS_IDENTICAL=", identical(sort(n$ensembl_gene_id), sort(r$ensembl_gene_id)), "\n", sep = "")
m <- merge(n, r, by = "ensembl_gene_id", suffixes = c(".n", ".r"))
cat("LFC_COR=", sprintf("%.5f", cor(m$log2FoldChange.n, m$log2FoldChange.r, use = "complete.obs")), "\n", sep = "")
cat("SIG_NEW=", cn["sig"], "\nSIG_REF=", cr["sig"], "\n", sep = "")
cat("UP_NEW=", cn["up"], "\nUP_REF=", cr["up"], "\nDOWN_NEW=", cn["down"], "\nDOWN_REF=", cr["down"], "\n", sep = "")
EOF

cat > "$LOGS/chk_pca.R" <<'EOF'
# PCA on the vst data: KO and Wt must separate along PC1 or PC2
a <- commandArgs(TRUE)
v <- read.delim(a[1], check.names = FALSE)
p <- prcomp(t(v), scale. = TRUE)
ko <- colnames(v) %in% c("SRR3222409", "SRR3222410", "SRR3222411")
sep <- function(x) max(x[ko]) < min(x[!ko]) || max(x[!ko]) < min(x[ko])
ve <- 100 * p$sdev^2 / sum(p$sdev^2)
cat("NCOL=", ncol(v), "\n", sep = "")
cat("PC1_SEPARATES=", sep(p$x[, 1]), "\nPC2_SEPARATES=", sep(p$x[, 2]), "\n", sep = "")
cat("PC1_VAR=", sprintf("%.1f", ve[1]), "\nPC2_VAR=", sprintf("%.1f", ve[2]), "\n", sep = "")
EOF

echo "======================================================================="
echo "🚀 End-to-end validation of the RNA-seq Lab"
echo "📂 Working directory: $ROOT"
echo "======================================================================="

# -----------------------------------------------------------------------------
# STEP 0 - Environment, tools, R packages
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 0: preflight ━━"

if command -v conda >/dev/null 2>&1; then
  eval "$(conda shell.bash hook)"
  conda activate "$ENV_NAME" >"$LOGS/00_conda.log" 2>&1
fi
if [ "${CONDA_DEFAULT_ENV:-}" = "$ENV_NAME" ]; then
  add PASS "Conda environment '$ENV_NAME' is active"
else
  add WARN "Conda environment '$ENV_NAME' is NOT active (using the tools found in PATH)" "CONDA_DEFAULT_ENV='${CONDA_DEFAULT_ENV:-}'"
fi

# isolate R from the user's own libraries
export R_LIBS_USER=""
export R_LIBS_SITE=""

missing=()
for t in wget gzip gunzip hisat2 hisat2-build samtools featureCounts fastqc multiqc Rscript file; do
  command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if [ ${#missing[@]} -gt 0 ]; then
  add FAIL "Command-line tools are installed" "missing: ${missing[*]}"
  finish
fi
FQC_VER="$(fastqc --version 2>&1 | head -1)"
ver="hisat2 $(hisat2 --version 2>&1 | head -1 | awk '{print $NF}')"
ver="$ver | $(samtools --version 2>&1 | head -1)"
ver="$ver | $(featureCounts -v 2>&1 | grep -i featureCounts | head -1 | xargs)"
ver="$ver | $FQC_VER"
ver="$ver | $(multiqc --version 2>&1 | head -1)"
ver="$ver | $(R --version 2>/dev/null | grep -m1 '^R version' | cut -d' ' -f1-3)"
add PASS "Tools found (hisat2, samtools, featureCounts, fastqc, multiqc, R)" "$ver"

if Rscript "$LOGS/chk_pkgs.R" >"$LOGS/00_rpkgs.log" 2>&1; then
  miss=$(kv "$LOGS/00_rpkgs.log" MISSING)
  if [ -z "$miss" ]; then
    add PASS "R packages (DESeq2, edgeR, goseq, reactome.db, org.Mm.eg.db, EnsDb.Mmusculus.v79, pheatmap, tidyverse)" \
      "$(kv "$LOGS/00_rpkgs.log" VERSIONS | tr ';' '\n' | grep -E 'DESeq2|goseq' | xargs)"
  else
    add FAIL "R packages installed" "missing: $miss  (the R steps that need them will fail)"
  fi
else
  add FAIL "Rscript works" "see $LOGS/00_rpkgs.log"
fi

free_gb=$(df -P -BG "$HOME" | awk 'NR==2{gsub("G","",$4); print $4}')
if fge "$free_gb" 5; then add PASS "Disk space in \$HOME" "${free_gb} GB free (~3 GB needed)"
else add WARN "Disk space in \$HOME" "${free_gb} GB free: might not be enough (~3 GB needed)"; fi

# -----------------------------------------------------------------------------
# STEP 1 - Folder layout + fastq download
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 1: folders and fastq download ━━"
mkdir -p "$LAB" && cd "$LAB" || exit 1
mkdir -p 1_raw 2_fastqc 3_mapping 4_dge 5_multiqc reference scripts funannot plots
mkdir -p reference/mouse_chr19_hisat2
dirs_ok=1
for d in 1_raw 2_fastqc 3_mapping 4_dge 5_multiqc reference reference/mouse_chr19_hisat2 scripts funannot plots; do
  [ -d "$LAB/$d" ] || dirs_ok=0; done
[ $dirs_ok -eq 1 ] && add PASS "Lab folder layout created" "1_raw 2_fastqc 3_mapping 4_dge 5_multiqc reference scripts funannot plots"

{ echo '#!/bin/bash'; echo
  for s in "${SAMPLES[@]}"; do for r in 1 2; do echo "wget -nv $URL_DATA/${s}-19_${r}.fq.gz"; done; done
} > scripts/get_data.sh

run "Download 12 fastq (get_data.sh)" "$LOGS/01_get_data.log" in_dir 1_raw bash ../scripts/get_data.sh
rc=$?
fq=( "$LAB"/1_raw/*.fq.gz )
if [ $rc -eq 0 ] && [ ${#fq[@]} -eq 12 ]; then
  add PASS "12 fastq files downloaded" "${#fq[@]} files in 1_raw ($(du -sh 1_raw | cut -f1))"
else
  add FAIL "12 fastq files downloaded" "found ${#fq[@]}/12, wget exit=$rc  (see $LOGS/01_get_data.log)"
fi

if [ ${#fq[@]} -gt 0 ]; then
  badgz=(); for f in "${fq[@]}"; do gzip -t "$f" 2>/dev/null || badgz+=("$(basename "$f")"); done
  if [ ${#badgz[@]} -eq 0 ]; then add PASS "All fastq.gz files are intact gzip archives"
  else add FAIL "Corrupted/truncated fastq.gz files" "${badgz[*]}"; fi

  echo "   (counting reads in every fastq...)"
  mism=(); summ=""
  for s in "${SAMPLES[@]}"; do
    f1="1_raw/${s}-19_1.fq.gz"; f2="1_raw/${s}-19_2.fq.gz"
    if [ -s "$f1" ] && [ -s "$f2" ]; then
      n1=$(zcat "$f1" | awk 'END{print NR/4}'); n2=$(zcat "$f2" | awk 'END{print NR/4}')
      [ "$n1" = "$n2" ] || mism+=("$s:$n1!=$n2")
      summ="$summ $s=$n1"
      [ "$s" = "SRR3222409" ] && N1_S1=$n1
    else mism+=("$s:file missing"); fi
  done
  if [ ${#mism[@]} -eq 0 ]; then add PASS "R1 reads == R2 reads for every sample (pairs intact)" "pairs:${summ}"
  else add FAIL "R1/R2 read counts differ" "${mism[*]}"; fi
  if [ "${N1_S1:-0}" = "$EXP_S1_PAIRS" ]; then
    add PASS "SRR3222409 has $EXP_S1_PAIRS pairs (matches the expected baseline)"
  else
    add WARN "SRR3222409 has ${N1_S1:-?} pairs, baseline expects $EXP_S1_PAIRS" "data changed? verify the input data/baseline"
  fi
fi

# -----------------------------------------------------------------------------
# STEP 2 - Reference (chr19 genome + Ensembl 99 GTF)
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 2: genome and annotation ━━"
cat > scripts/get_ref.sh <<EOF
#!/bin/bash
wget -nv $URL_ENS/fasta/mus_musculus/dna/Mus_musculus.GRCm38.dna.chromosome.19.fa.gz
wget -nv $URL_ENS/gtf/mus_musculus/Mus_musculus.GRCm38.99.gtf.gz
gunzip Mus_musculus.GRCm38.dna.chromosome.19.fa.gz
gunzip Mus_musculus.GRCm38.99.gtf.gz
cat Mus_musculus.GRCm38.99.gtf | grep -E "^#|^19" > Mus_musculus.GRCm38.99-19.gtf
EOF
run "Download + gunzip + chr19 GTF extraction" "$LOGS/02_reference.log" in_dir reference bash ../scripts/get_ref.sh
FA="$LAB/reference/Mus_musculus.GRCm38.dna.chromosome.19.fa"
GTF="$LAB/reference/Mus_musculus.GRCm38.99.gtf"
GTF19="$LAB/reference/Mus_musculus.GRCm38.99-19.gtf"
if need "Genome/GTF checks" "$FA" "$GTF" "$GTF19"; then
  hdr=$(head -1 "$FA")
  len=$(awk '!/^>/{n+=length($0)} END{print n}' "$FA")
  if [[ "$hdr" == ">19 "* ]] && [ "$len" = "$EXP_CHR19_LEN" ]; then
    add PASS "FASTA = complete GRCm38 chromosome 19" "$hdr  |  ${len} bp"
  elif [[ "$hdr" == ">19 "* ]]; then
    add WARN "FASTA is chr19 but with an unexpected length" "${len} bp (expected $EXP_CHR19_LEN)"
  else
    add FAIL "FASTA is not chr19" "header: $hdr"
  fi
  full19=$(awk '!/^#/ && $1=="19"' "$GTF" | wc -l)
  sub19=$(grep -vc '^#' "$GTF19")
  g19=$(awk '$1=="19" && $3=="gene"' "$GTF" | wc -l)
  if [ "$full19" = "$sub19" ] && [ "$sub19" -gt 0 ] && [ "$g19" -gt 500 ]; then
    add PASS "chr19 GTF is consistent with the full GTF" "$sub19 lines, $g19 genes on chr19 | full=$(du -h "$GTF" | cut -f1), chr19=$(du -h "$GTF19" | cut -f1), fa=$(du -h "$FA" | cut -f1)"
  else
    add FAIL "chr19 GTF is inconsistent" "full GTF chr19 lines=$full19 vs subset=$sub19, genes=$g19"
  fi
fi

# -----------------------------------------------------------------------------
# STEP 3 - FastQC
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 3: FastQC ━━"
cat > scripts/fastqc.sh <<'EOF'
#!/usr/bin/env bash
# Run from 2_fastqc/; use the supported long option (FastQC 0.13+).
fastqc --outdir . ../1_raw/*.fq.gz
EOF
if need "FastQC execution" "${fq[0]:-/nonexistent}"; then
  run "FastQC on 12 FASTQ files (--outdir)" "$LOGS/03_fastqc.log" in_dir 2_fastqc bash ../scripts/fastqc.sh
  rc=$?
  if [ "$rc" -ne 0 ]; then
    add FAIL "FastQC execution" "exit=$rc; see $LOGS/03_fastqc.log"
  fi
fi
nh=$(ls 2_fastqc/*_fastqc.html 2>/dev/null | wc -l); nz=$(ls 2_fastqc/*_fastqc.zip 2>/dev/null | wc -l)
if [ "$nh" -eq 12 ] && [ "$nz" -eq 12 ]; then add PASS "FastQC output: 12 .html + 12 .zip (one per fastq)"
else add FAIL "FastQC output incomplete" "html=$nh zip=$nz (expected 12+12) - see $LOGS/03_fastqc.log"; fi
if [ "$nz" -gt 0 ]; then
  if command -v unzip >/dev/null 2>&1; then
    p=0; w=0; f=0; u=0
    for z in 2_fastqc/*_fastqc.zip; do
      s=$(unzip -p "$z" '*/summary.txt' 2>/dev/null | awk -F'\t' '$2=="Per base sequence quality"{print $1; exit}')
      case $s in PASS) p=$((p+1));; WARN) w=$((w+1));; FAIL) f=$((f+1));; *) u=$((u+1));; esac
    done
    if [ $u -gt 0 ]; then add FAIL "FastQC zip files contain a readable summary.txt" "$u of $nz zip files have no readable 'Per base sequence quality' entry"
    elif [ $f -gt 0 ]; then add WARN "FastQC 'Per base sequence quality' has FAILs" "PASS=$p WARN=$w FAIL=$f out of $nz files"
    else add PASS "FastQC 'Per base sequence quality'" "PASS=$p WARN=$w FAIL=$f out of $nz files"; fi
  else
    add SKIP "Reading summary.txt inside the FastQC zip files" "unzip is not installed"
  fi
fi

# -----------------------------------------------------------------------------
# STEP 4 - HISAT2: index, mapping, BAM indexing
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 4: HISAT2 ━━"
cat > scripts/hisat2_index.sh <<'EOF'
#!/bin/bash

hisat2-build \
  -p 1 \
  Mus_musculus.GRCm38.dna.chromosome.19.fa \
  mouse_chr19_hisat2/mouse_chr19_hisat2
EOF
sed -i "s/-p 1/-p $THREADS/" scripts/hisat2_index.sh

run "hisat2-build (chr19 index)" "$LOGS/04_hisat2_index.log" in_dir reference bash ../scripts/hisat2_index.sh
idx=0; idxempty=0
for i in 1 2 3 4 5 6 7 8; do
  f="reference/mouse_chr19_hisat2/mouse_chr19_hisat2.$i.ht2"
  [ -f "$f" ] && idx=$((idx+1)); [ -f "$f" ] && [ ! -s "$f" ] && idxempty=$((idxempty+1))
done
if [ $idx -eq 8 ] && [ $idxempty -eq 0 ]; then
  add PASS "HISAT2 index: 8 non-empty .ht2 files" "$(du -sh reference/mouse_chr19_hisat2 | cut -f1) in total"
else
  add FAIL "HISAT2 index incomplete" "$idx/8 files (empty: $idxempty) - see $LOGS/04_hisat2_index.log"
fi

cat > scripts/hisat2_align.sh <<'EOF'
#!/bin/bash

# get output filename prefix
prefix=$( basename $1 | sed -E 's/_.+$//' )

hisat2 \
  -p 1 \
  -x ../reference/mouse_chr19_hisat2/mouse_chr19_hisat2 \
  --summary-file "${prefix}.summary" \
  -1 $1 \
  -2 $2 | samtools sort -O BAM > "${prefix}.bam"
EOF
sed -i "s/-p 1/-p $THREADS/" scripts/hisat2_align.sh

cat > scripts/hisat2_align_batch.sh <<'EOF'
#!/bin/bash

# Loop through each read1 file
for r1 in ../1_raw/*1.fq.gz; do
  # Define the corresponding read2 file by replacing "r1" with "r2" in the filename

  r2="${r1/1.fq.gz/2.fq.gz}"

  # Extract the base name of the sample
  sample_name=$(basename "$r1" | sed 's/_1.fastq.gz//')

  # Define output files
  out_sam="./${sample_name}.sam"

  ## use the sample name and add suffix (_1.fq.gz or _2.fq.gz)
  echo "Mapping ${r1} and ${r2} ..."
  bash ../scripts/hisat2_align.sh ${r1} ${r2}
done
EOF

if need "HISAT2 mapping" "$LAB/reference/mouse_chr19_hisat2/mouse_chr19_hisat2.1.ht2" "${fq[0]:-/nonexistent}"; then
  run "hisat2_align_batch.sh (6 samples)" "$LOGS/05_hisat2_align.log" in_dir 3_mapping bash ../scripts/hisat2_align_batch.sh
fi
bams=( "$LAB"/3_mapping/*.bam ); sums=( "$LAB"/3_mapping/*.summary )
if [ ${#bams[@]} -eq 6 ] && [ ${#sums[@]} -eq 6 ]; then
  add PASS "Mapping: 6 BAM + 6 .summary files with the expected names" "$(basename "${bams[0]}") ... $(basename "${bams[5]}")"
else
  add FAIL "Mapping: incomplete output" "bam=${#bams[@]} summary=${#sums[@]} (expected 6+6) - see $LOGS/05_hisat2_align.log"
fi

if [ ${#bams[@]} -gt 0 ]; then
  badq=(); unsorted=(); empty=()
  for b in "${bams[@]}"; do
    [ -s "$b" ] || { empty+=("$(basename "$b")"); continue; }
    samtools quickcheck -v "$b" >/dev/null 2>&1 || badq+=("$(basename "$b")")
    samtools view -H "$b" 2>/dev/null | grep -q 'SO:coordinate' || unsorted+=("$(basename "$b")")
  done
  if [ ${#empty[@]} -eq 0 ] && [ ${#badq[@]} -eq 0 ]; then add PASS "BAM files are non-empty and valid (samtools quickcheck)"
  else add FAIL "Empty or corrupted BAM files" "empty: ${empty[*]:-none}  corrupted: ${badq[*]:-none}"; fi
  if [ ${#unsorted[@]} -eq 0 ]; then add PASS "BAM files are coordinate-sorted (SO:coordinate)"
  else add FAIL "Unsorted BAM files" "${unsorted[*]}"; fi
fi

if [ ${#sums[@]} -gt 0 ]; then
  low=(); mid=(); line=""; wrongreads=0
  for s in "${sums[@]}"; do
    name=$(basename "$s" .summary)
    reads=$(awk 'NR==1{print $1}' "$s"); rate=$(awk '/overall alignment rate/{gsub("%","",$1); print $1}' "$s")
    line="$line $name:${reads}pairs/${rate}%;"
    [ -z "$rate" ] && { low+=("$name(no rate)"); continue; }
    if flt "$rate" 90; then low+=("$name=$rate"); elif flt "$rate" 95; then mid+=("$name=$rate"); fi
    if [ "$name" = "SRR3222409-19" ]; then
      [ "$reads" = "$EXP_S1_PAIRS" ] || wrongreads=1
      S1RATE=$rate
    fi
  done
  if [ ${#low[@]} -gt 0 ]; then add FAIL "Overall alignment rate < 90%" "${low[*]}"
  elif [ ${#mid[@]} -gt 0 ]; then add WARN "Overall alignment rate between 90 and 95%" "${mid[*]}"
  else add PASS "Overall alignment rate >= 95% in every sample" "$line"; fi
  if [ -n "${S1RATE:-}" ]; then
    if awk -v a="$S1RATE" -v b="$EXP_S1_RATE" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=0.5)}' && [ $wrongreads -eq 0 ]; then
      add PASS "SRR3222409-19 matches the expected alignment baseline" "${S1RATE}% (baseline: ${EXP_S1_RATE}%), $EXP_S1_PAIRS pairs"
    else
      add WARN "SRR3222409-19 differs from the alignment baseline" "rate=${S1RATE}% (baseline ${EXP_S1_RATE}%) - verify HISAT2 version and input data"
    fi
  fi
fi

if [ ${#bams[@]} -gt 0 ] && [ -s "${bams[0]}" ]; then
  worst=100
  for b in "${bams[@]}"; do
    [ -s "$b" ] || continue
    samtools index "$b" >/dev/null 2>&1   # temporary index, needed by idxstats
    pct=$(samtools idxstats "$b" | awk '{if($1=="19")m=$3; t+=$3} END{if(t>0)printf "%.2f",100*m/t; else print 0}')
    flt "$pct" "$worst" && worst=$pct
  done
  rm -f "$LAB"/3_mapping/*.bai   # the lab's own indexing step recreates them from scratch
  if fge "$worst" 99.9; then add PASS "All mapped reads are on chr19 (idxstats)" "minimum $worst%"
  else add WARN "Reads mapped outside chr19?" "minimum $worst% on contig 19"; fi
fi

cat > scripts/samtools_index_bam.sh <<'EOF'
#!/bin/bash

for i in *.bam
  do
    echo "Indexing $i ..."
    samtools index $i
  done
EOF
run "samtools_index_bam.sh" "$LOGS/06_samtools_index.log" in_dir 3_mapping bash ../scripts/samtools_index_bam.sh
bai=( "$LAB"/3_mapping/*.bam.bai )
if [ ${#bai[@]} -eq 6 ]; then
  add PASS "BAM indexing: 6 .bam.bai files created" "$(du -ch "${bai[@]}" | tail -1 | cut -f1) in total"
else
  add FAIL "BAM indexing" "${#bai[@]}/6 .bai files - see $LOGS/06_samtools_index.log"
fi

# -----------------------------------------------------------------------------
# STEP 5 - featureCounts + counts_full.txt
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 5: featureCounts ━━"
cat > scripts/featurecounts.sh <<'EOF'
#!/bin/bash

featureCounts \
  -a "../reference/Mus_musculus.GRCm38.99.gtf" \
  -o "counts.txt" \
  -F "GTF" \
  -t "exon" \
  -g "gene_id" \
  -p \
  -s 0 \
  -T 1 \
  ../3_mapping/*.bam
EOF
sed -i "s/-T 1/-T $THREADS/" scripts/featurecounts.sh

if need "featureCounts" "$GTF" "${bams[0]:-/nonexistent}"; then
  run "featurecounts.sh (full GTF)" "$LOGS/07_featurecounts.log" in_dir 4_dge bash ../scripts/featurecounts.sh
fi
run "wget counts_full.txt (lab backup)" "$LOGS/07b_counts_full.log" in_dir 4_dge wget -nv "$URL_RAW/counts_full.txt"

CNT="$LAB/4_dge/counts.txt"; CNTS="$LAB/4_dge/counts.txt.summary"; CF="$LAB/4_dge/counts_full.txt"
if [ -s "$CNT" ] && [ -s "$CNTS" ]; then
  add PASS "featureCounts: counts.txt + counts.txt.summary produced"
else
  add FAIL "featureCounts: output files missing" "see $LOGS/07_featurecounts.log"
fi
if [ -s "$CNTS" ]; then
  awk -F'\t' 'NR==1{nf=NF; for(i=2;i<=nf;i++)n[i]=$i}
              NR>1{for(i=2;i<=nf;i++)t[i]+=$i; if($1=="Assigned")for(i=2;i<=nf;i++)a[i]=$i}
              END{for(i=2;i<=nf;i++)printf "%s %.1f\n", n[i], (t[i]>0?100*a[i]/t[i]:0)}' "$CNTS" \
    | sed -E 's/^.*(SRR[0-9]+)[^ ]* /\1 /' > "$LOGS/07_assigned.txt"
  minA=$(awk '{print $2}' "$LOGS/07_assigned.txt" | sort -n | head -1)
  lineA=$(awk '{printf "%s=%s%% ", $1, $2}' "$LOGS/07_assigned.txt")
  if flt "$minA" 20; then add FAIL "featureCounts: Assigned fragments % is too low (<20%)" "$lineA"
  elif flt "$minA" 40; then add WARN "featureCounts: Assigned fragments % is low (<40%)" "$lineA"
  else add PASS "featureCounts: Assigned fragments" "$lineA"; fi
fi
if [ -s "$CF" ]; then
  add PASS "counts_full.txt downloaded" "$(du -h "$CF" | cut -f1), $(($(wc -l < "$CF")-2)) genes"
else
  add FAIL "counts_full.txt not downloaded" "see $LOGS/07b_counts_full.log"
fi
if [ -s "$CNT" ] && [ -s "$CF" ]; then
  if Rscript "$LOGS/chk_counts.R" "$CNT" "$CF" > "$LOGS/07c_counts_check.log" 2>&1; then
    L="$LOGS/07c_counts_check.log"
    [ "$(kv "$L" NSAMPLES)" = "6" ] && add PASS "counts.txt has 6 sample columns" "$(kv "$L" SAMPLES)" \
                                    || add FAIL "counts.txt: wrong number of samples" "$(kv "$L" NSAMPLES)"
    if [ "$(kv "$L" IDS_IDENTICAL)" = "TRUE" ]; then
      add PASS "Gene IDs in counts.txt == gene IDs in counts_full.txt (same Ensembl 99 annotation)" "$(kv "$L" NGENES_X) genes"
    else
      add FAIL "Gene IDs in counts.txt differ from counts_full.txt" "x=$(kv "$L" NGENES_X) full=$(kv "$L" NGENES_Y): annotation differs from the backup"
    fi
    off=$(kv "$L" COUNTS_OFF_CHR19); on=$(kv "$L" COUNTS_ON_CHR19)
    if [ "${off:-1}" = "0" ] && [ "${on:-0}" -gt 0 ]; then
      add PASS "Counts only on chr19 genes (off-chr19 = 0)" "$on fragments over $(kv "$L" N_CHR19_GENES) chr19 genes"
    else
      add FAIL "Unexpected counts outside chr19" "off-chr19=$off on-chr19=$on"
    fi
    if [ "$(kv "$L" BEST_MATCH_OK)" = "TRUE" ] && fge "$(kv "$L" RHO_DIAG_MIN)" 0.8; then
      add PASS "Each chr19 sample correlates best with ITS OWN sample in counts_full (no swaps)" "Spearman diagonal: $(kv "$L" RHO_DIAG)"
    elif [ "$(kv "$L" BEST_MATCH_OK)" = "TRUE" ]; then
      add WARN "Samples matched correctly but the correlation is low" "Spearman diagonal: $(kv "$L" RHO_DIAG)"
    else
      add FAIL "Possible sample swap compared with counts_full" "Spearman diagonal: $(kv "$L" RHO_DIAG)"
    fi
  else
    add FAIL "Comparison of counts.txt vs counts_full.txt" "see $LOGS/07c_counts_check.log"
  fi
fi

# -----------------------------------------------------------------------------
# STEP 6 - MultiQC
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 6: MultiQC ━━"
run "multiqc --interactive ../" "$LOGS/08_multiqc.log" in_dir 5_multiqc multiqc --interactive ../
MQ="$LAB/5_multiqc"
if [ -s "$MQ/multiqc_report.html" ] && [ -d "$MQ/multiqc_data" ]; then
  add PASS "MultiQC: multiqc_report.html + multiqc_data/" "$(du -h "$MQ/multiqc_report.html" | cut -f1)"
else
  add FAIL "MultiQC: report not generated" "see $LOGS/08_multiqc.log"
fi
MQSRC="$MQ/multiqc_data/multiqc_sources.txt"
if [ -s "$MQSRC" ]; then
  nfq=$(awk -F'\t' 'NR>1 && tolower($1)~/fastqc/{print $3}' "$MQSRC" | sort -u | wc -l)
  nfc=$(awk -F'\t' 'NR>1 && tolower($1)~/featurecounts/{print $3}' "$MQSRC" | sort -u | wc -l)
  nal=$(awk -F'\t' 'NR>1 && tolower($1)~/bowtie|hisat/{print $3}' "$MQSRC" | sort -u | wc -l)
  if [ "$nfq" -eq 12 ]; then add PASS "MultiQC found 12 FastQC reports"
  else add FAIL "MultiQC: FastQC reports" "found $nfq (expected 12); fastqc zips on disk: $nz; modules seen: $(awk -F'\t' 'NR>1{print $1}' "$MQSRC" | sort -u | xargs)"; fi
  [ "$nfc" -eq 6 ]  && add PASS "MultiQC found 6 featureCounts reports" || add FAIL "MultiQC: featureCounts reports" "found $nfc (expected 6)"
  [ "$nal" -eq 6 ]  && add PASS "MultiQC found 6 alignment reports (HISAT2 summaries parsed as 'bowtie2')" \
                    || add FAIL "MultiQC: alignment reports" "found $nal (expected 6)"
else
  add WARN "multiqc_sources.txt not found (different MultiQC version?)" "check the 'Found N reports' lines in $LOGS/08_multiqc.log by hand"
fi

# -----------------------------------------------------------------------------
# STEP 7 - DESeq2 (dge.R)
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 7: DESeq2 ━━"
for f in dge_results_full.txt counts_vst_full.txt; do
  wget -nv -O "$REFOUT/$f" "$URL_RAW/$f" >>"$LOGS/09_refoutputs.log" 2>&1
done
run "wget dge.R" "$LOGS/09_wget_dge.log" in_dir 4_dge wget -nv "$URL_RAW/scripts/R/dge.R"
if need "Rscript dge.R" "$LAB/4_dge/dge.R" "$CF"; then
  run "Rscript dge.R" "$LOGS/09_dge.log" in_dir 4_dge Rscript dge.R
  rc=$?
else rc=99; fi
D="$LAB/4_dge"
outs=0; for f in counts_vst_full.txt counts_vst_full.Rds dge_results_full.txt dge_results_full.Rds; do [ -s "$D/$f" ] && outs=$((outs+1)); done
if [ $rc -eq 0 ] && [ $outs -eq 4 ] && grep -q '^Completed' "$LOGS/09_dge.log"; then
  add PASS "dge.R completed: 4 output files produced" "counts_vst_full.{txt,Rds} dge_results_full.{txt,Rds}"
elif [ $rc -ne 99 ]; then
  add FAIL "dge.R did not complete" "exit=$rc, outputs $outs/4 - see $LOGS/09_dge.log"
fi
if [ -s "$LOGS/09_dge.log" ]; then
  grep -qE '^\[1\] TRUE' "$LOGS/09_dge.log" \
    && add PASS "Count columns are in the same order as the metadata (all.equal = TRUE in the log)" \
    || add FAIL "all.equal() is not TRUE: count columns not aligned with the metadata" "see $LOGS/09_dge.log"
  grep -q 'condition_KO_vs_Wt' "$LOGS/09_dge.log" \
    && add PASS "DESeq2 contrast = condition_KO_vs_Wt" \
    || add WARN "Contrast 'condition_KO_vs_Wt' not found in the log"
fi
if [ -s "$D/dge_results_full.txt" ] && [ -s "$REFOUT/dge_results_full.txt" ]; then
  if Rscript "$LOGS/chk_dge.R" "$D/dge_results_full.txt" "$REFOUT/dge_results_full.txt" >"$LOGS/09b_dge_check.log" 2>&1; then
    L="$LOGS/09b_dge_check.log"
    if [ "$(kv "$L" IDS_IDENTICAL)" = "TRUE" ]; then
      add PASS "Same genes tested as in the reference file" "$(kv "$L" N_NEW) genes (ref $(kv "$L" N_REF))"
    else
      add FAIL "Tested genes differ from the reference" "new=$(kv "$L" N_NEW) ref=$(kv "$L" N_REF)"
    fi
    cor=$(kv "$L" LFC_COR)
    if fge "$cor" 0.999; then add PASS "log2FC identical to the reference" "correlation = $cor"
    elif fge "$cor" 0.99; then add WARN "log2FC almost identical to the reference" "correlation = $cor"
    else add FAIL "log2FC differ from the reference" "correlation = $cor"; fi
    sn=$(kv "$L" SIG_NEW); sr=$(kv "$L" SIG_REF)
    if awk -v a="$sn" -v b="$sr" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(b>0 && d/b<=0.02)}'; then
      add PASS "Number of DE genes (padj<0.05) matches the reference (±2%)" "new=$sn  ref=$sr | up(LFC>0.5)=$(kv "$L" UP_NEW)/$(kv "$L" UP_REF) down=$(kv "$L" DOWN_NEW)/$(kv "$L" DOWN_REF)"
    else
      add WARN "Number of DE genes differs from the reference" "new=$sn  ref=$sr"
    fi
  else
    add FAIL "DGE comparison with the reference" "see $LOGS/09b_dge_check.log"
  fi
else
  add SKIP "DGE comparison with the reference" "dge_results_full.txt missing (new or reference)"
fi

# -----------------------------------------------------------------------------
# STEP 8 - Functional annotation (bonus)
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 8: functional annotation (goseq / Reactome) ━━"
if [ "$SKIP_ANNOT" = "1" ]; then
  add SKIP "Functional annotation" "SKIP_ANNOT=1"
else
  run "wget annotate_de_results.R" "$LOGS/10_wget_annot.log" in_dir funannot wget -nv "$URL_RAW/scripts/R/annotate_de_results.R"
  # mm-biomart99-genes.txt is placed in reference/ for the annotation script
  run "wget mm-biomart99-genes.txt (into reference/)" "$LOGS/10_wget_biomart.log" in_dir reference wget -nv "$URL_RAW/mm-biomart99-genes.txt"
  if need "Rscript annotate_de_results.R" "$LAB/funannot/annotate_de_results.R" "$LAB/reference/mm-biomart99-genes.txt" "$D/dge_results_full.txt"; then
    run "Rscript annotate_de_results.R" "$LOGS/10_annot.log" in_dir funannot Rscript annotate_de_results.R
    rc=$?
    FA_D="$LAB/funannot"; ok=1; sz=""
    for f in go_up go_down reactome_up reactome_down; do
      [ -s "$FA_D/$f.txt" ] || ok=0; sz="$sz $f=$(($(wc -l < "$FA_D/$f.txt" 2>/dev/null || echo 1)-1))"
    done
    if [ $rc -eq 0 ] && [ $ok -eq 1 ]; then
      add PASS "annotate_de_results.R: 4 tables produced (term rows:$sz)"
      if [ "$(head -1 "$FA_D/go_up.txt" | cut -f1)" = "category" ] && head -1 "$FA_D/reactome_up.txt" | grep -q PATHNAME \
         && [ "$(($(wc -l < "$FA_D/go_up.txt")-1))" -gt 1000 ]; then
        add PASS "Expected headers (category..., PATHNAME) and >1000 GO terms"
      else
        add FAIL "Unexpected format of the functional tables" "head go_up: $(head -1 "$FA_D/go_up.txt" | cut -c1-80)"
      fi
      nm=$(sed -n '2,21p' "$FA_D/go_up.txt" | awk -F'\t' '{print $6}' | grep -ciE 'muscle|myofibril|sarcomere|contractile|striated|myosin')
      top3=$(awk -F'\t' 'NR>=2&&NR<=4{printf "%s; ",$6}' "$FA_D/go_up.txt")
      topp=$(awk -F'\t' 'NR==2{print $2}' "$FA_D/go_up.txt")
      if [ "$nm" -ge 5 ] && flt "$topp" 1e-20; then
        add PASS "Up-regulated GO: expected muscle terms dominate" "$nm/20 muscle terms; top: $top3 p=$topp"
      else
        add FAIL "Up-regulated GO: the expected muscle terms are not there" "$nm/20 muscle terms; top: $top3 p=$topp"
      fi
      add PASS "Top Reactome pathway up / down" "up: $(awk -F'\t' 'NR==2{print $NF}' "$FA_D/reactome_up.txt") | down: $(awk -F'\t' 'NR==2{print $NF}' "$FA_D/reactome_down.txt")"
    else
      add FAIL "annotate_de_results.R did not complete" "exit=$rc, tables ok=$ok - see $LOGS/10_annot.log"
    fi
  fi
fi

# -----------------------------------------------------------------------------
# STEP 9 - Plots
# -----------------------------------------------------------------------------
echo; echo "━━ STEP 9: plots (PCA, MA, volcano, heatmap) ━━"
run "wget plot_figures.R" "$LOGS/11_wget_plots.log" in_dir plots wget -nv "$URL_RAW/scripts/R/plot_figures.R"
if need "Rscript plot_figures.R" "$LAB/plots/plot_figures.R" "$D/dge_results_full.txt" "$D/counts_vst_full.txt"; then
  run "Rscript plot_figures.R" "$LOGS/11_plots.log" in_dir plots Rscript plot_figures.R
  rc=$?
  PL="$LAB/plots"; badp=(); info=""
  for spec in "pca_plot.png:480 x 480" "ma_plot.png:480 x 480" "volcano_plot.png:480 x 480" "heatmap_top_50.png:480 x 800"; do
    f=${spec%%:*}; want=${spec#*:}
    if [ ! -s "$PL/$f" ]; then badp+=("$f missing"); continue; fi
    dim=$(file "$PL/$f" | grep -oE '[0-9]+ x [0-9]+' | head -1); kb=$(( $(stat -c %s "$PL/$f") / 1024 ))
    info="$info $f(${dim},${kb}KB)"
    [ "$dim" = "$want" ] || badp+=("$f size $dim (expected $want)")
    [ "$kb" -ge 8 ] || badp+=("$f suspiciously small (${kb}KB: empty plot?)")
  done
  if [ $rc -eq 0 ] && [ ${#badp[@]} -eq 0 ]; then
    add PASS "plot_figures.R: 4 correct PNG files (right size, not empty)" "$info"
  else
    add FAIL "plot_figures.R: problems" "exit=$rc ${badp[*]:-} - see $LOGS/11_plots.log"
  fi
  if Rscript "$LOGS/chk_pca.R" "$D/counts_vst_full.txt" >"$LOGS/11b_pca.log" 2>&1; then
    L="$LOGS/11b_pca.log"
    if [ "$(kv "$L" PC1_SEPARATES)" = "TRUE" ] || [ "$(kv "$L" PC2_SEPARATES)" = "TRUE" ]; then
      add PASS "PCA: KO and Wt separate perfectly" "PC1 separates=$(kv "$L" PC1_SEPARATES) ($(kv "$L" PC1_VAR)% var), PC2 separates=$(kv "$L" PC2_SEPARATES) ($(kv "$L" PC2_VAR)% var)"
    else
      add FAIL "PCA: KO and Wt do NOT separate (swapped samples or wrong data?)" "PC1=$(kv "$L" PC1_VAR)% PC2=$(kv "$L" PC2_VAR)%"
    fi
  fi
fi

finish
SCIENTIFIC_VALIDATOR_EOF
# =============================================================================
# <<< end of embedded scientific validator >>>
# =============================================================================

# Hand the temporary environment name to the scientific validator via the
# variables it already understands (ENV_NAME, ROOT, THREADS, SKIP_ANNOT).
export ENV_NAME="$TMP_ENV"
export ROOT
export THREADS
export SKIP_ANNOT

bash "$SCI" 2>&1 | tee "$EV/scientific_run.log"
SCI_RC=${PIPESTATUS[0]}
info "scientific_exit: $SCI_RC"

# Parse the summary line of the scientific report.
sci_pass=""; sci_warn=""; sci_fail=""; sci_skip=""
if [ -s "$ROOT/REPORT.txt" ]; then
  sci_pass="$(grep -oE 'PASS: [0-9]+' "$ROOT/REPORT.txt" | head -1 | grep -oE '[0-9]+')"
  sci_warn="$(grep -oE 'WARN: [0-9]+'  "$ROOT/REPORT.txt" | head -1 | grep -oE '[0-9]+')"
  sci_fail="$(grep -oE 'FAIL: [0-9]+'  "$ROOT/REPORT.txt" | head -1 | grep -oE '[0-9]+')"
  sci_skip="$(grep -oE 'SKIP: [0-9]+'  "$ROOT/REPORT.txt" | head -1 | grep -oE '[0-9]+')"
  {
    echo "# summary parsed from $ROOT/REPORT.txt"
    echo "PASS: ${sci_pass:-?}"
    echo "WARN: ${sci_warn:-?}"
    echo "FAIL: ${sci_fail:-?}"
    echo "SKIP: ${sci_skip:-?}"
    echo "scientific_exit_code: $SCI_RC"
  } > "$EV/report_summary.txt"
  if [ -s "$LOGS/00_rpkgs.log" ]; then
    cp "$LOGS/00_rpkgs.log" "$EV/r_package_versions.txt"
  else
    echo "R package versions not captured (the scientific run did not complete its preflight)." > "$EV/r_package_versions.txt"
  fi
else
  {
    echo "REPORT.txt missing - the scientific run did not complete."
    echo "scientific_exit_code: $SCI_RC"
  } > "$EV/report_summary.txt"
fi

# A SKIP is expected only when the instructor explicitly asked to skip the
# bonus annotation part (SKIP_ANNOT=1 produces exactly one SKIP).
allowed_skip=0
[ "$SKIP_ANNOT" = "1" ] && allowed_skip=1

sci_ok=1
if [ ! -s "$ROOT/REPORT.txt" ] || [ $SCI_RC -ne 0 ]; then
  sci_ok=0
else
  sf="${sci_fail:-1}"; ss="${sci_skip:-1}"
  case "$sf" in ''|*[!0-9]*) sf=1;; esac
  case "$ss" in ''|*[!0-9]*) ss=1;; esac
  if [ "$sf" -gt 0 ] || [ "$ss" -gt "$allowed_skip" ]; then
    sci_ok=0
  fi
fi

if [ $sci_ok -eq 1 ]; then
  echo "✅ Scientific validation OK: PASS=${sci_pass:-?} WARN=${sci_warn:-?} FAIL=0 SKIP=${sci_skip:-0} (allowed SKIP: $allowed_skip)."
  info "scientific_result: OK"
else
  echo "❌ Scientific validation FAILED (exit=$SCI_RC, FAIL=${sci_fail:-?}, SKIP=${sci_skip:-?}, allowed SKIP: $allowed_skip)." >&2
  echo "   Report: $ROOT/REPORT.txt" >&2
  echo "   Logs:   $LOGS" >&2
  info "scientific_result: FAILED (exit=$SCI_RC, FAIL=${sci_fail:-?}, SKIP=${sci_skip:-?})"
  if [ -z "$FINAL_RC" ]; then FINAL_RC=$RC_SCIENCE; fi
fi

# =============================================================================
# PHASE 7 — Cleanup (deactivate + remove) is performed by the EXIT trap above,
# which also finalizes $EV/run_info.txt and computes the exit code.
# =============================================================================
exit ${FINAL_RC:-0}