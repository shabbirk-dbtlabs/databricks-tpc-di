#!/usr/bin/env bash
# Load test: 50 concurrent dbt runs against Databricks, with and without state reuse.
#
# Usage:
#   ./loadtest.sh nostate    # 50 parallel runs with --no-manage-state
#   ./loadtest.sh state      # 50 parallel runs with state reuse enabled
#   ./loadtest.sh both       # nostate pass, then state pass
#
# Profiles test_user1 .. test_user50 must exist in profiles.yml.
# Each run gets its own --target-path so the 50 processes don't clobber target/.

set -uo pipefail

MODE="${1:-both}"
USERS="${2:-50}"
LOG_ROOT="loadtest_logs"
TS="$(date +%Y%m%d_%H%M%S)"

run_pass() {
    local label="$1"      # "nostate" or "state"
    local extra_flag="$2" # "--no-manage-state" or ""
    local log_dir="${LOG_ROOT}/${TS}_${label}"
    mkdir -p "${log_dir}"

    echo "=== Pass: ${label} (flag='${extra_flag}') ==="
    echo "Logs: ${log_dir}/"
    local start
    start=$(date +%s)

    seq 1 "${USERS}" | xargs -P "${USERS}" -I {} bash -c '
        i="$1"
        label="$2"
        log_dir="$3"
        extra_flag="$4"
        t_start=$(date +%s)
        dbt run \
            --target "test_user${i}" \
            --target-path "target/user${i}" \
            ${extra_flag} \
            > "${log_dir}/user${i}.log" 2>&1
        rc=$?
        t_end=$(date +%s)
        echo "user${i} rc=${rc} elapsed=$((t_end - t_start))s" \
            | tee -a "${log_dir}/_summary.txt"
    ' _ {} "${label}" "${log_dir}" "${extra_flag}"

    local end
    end=$(date +%s)
    echo "=== ${label} wall time: $((end - start))s ==="
    echo "Failures: $(grep -c 'rc=[^0]' "${log_dir}/_summary.txt" || true)"
    echo
}

case "${MODE}" in
    nostate) run_pass "nostate" "--no-manage-state" ;;
    state)   run_pass "state"   "" ;;
    both)
        run_pass "nostate" "--no-manage-state"
        run_pass "state"   ""
        ;;
    *) echo "Usage: $0 [nostate|state|both]"; exit 1 ;;
esac
