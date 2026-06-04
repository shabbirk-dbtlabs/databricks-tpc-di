#!/usr/bin/env bash
# Continuous, randomized "interactive developer" dbt activity for one simulated user.
# Args: USER_N  NOSTATE(0|1)  PROJDIR  LOGDIR  [DURATION_SECONDS]
set -uo pipefail

USER_N="$1"        # 1..10
NOSTATE="$2"       # 1 -> append --no-manage-state to run/build
PROJDIR="$3"       # isolated copy of the dbt project to run from
LOGDIR="$4"        # central dir for logs (in main project)
DURATION="${5:-1080}"

cd "$PROJDIR" || { echo "cannot cd $PROJDIR"; exit 1; }
TARGET="test_user${USER_N}"
TP="target/user${USER_N}"
SF=""
[ "$NOSTATE" = "1" ] && SF="--no-manage-state"

mkdir -p "$LOGDIR"
LOG="${LOGDIR}/user${USER_N}.log"
COHORT="state"; [ "$NOSTATE" = "1" ] && COHORT="nostate"

# every model except CustomerMgmt (slow, already built)
MODELS=(DimBroker DimDate DimTime TradeType StatusType TaxRate Industry \
        DimCompany DimSecurity DimAccount DimCustomer Prospect BatchDate \
        Financial FinWire FactWatches FactCashBalances FactHoldings \
        FactMarketHistory DimTrade)
# small/fast models for heavier actions (build/test/upstream)
SMALL=(DimBroker DimDate DimTime TradeType StatusType TaxRate Industry DimCompany DimSecurity)

AGG="Databricks_CSV/models/main/agg_user${USER_N}_dyn.sql"

ts(){ date '+%H:%M:%S'; }
log(){ echo "[$(ts)] $*" >> "$LOG"; }

echo "==== user${USER_N} START $(date) cohort=${COHORT} target=${TARGET} tp=${TP} dur=${DURATION}s ====" > "$LOG"

# Pre-flight: ensure CustomerMgmt exists in this user's schema. It is VERY slow to
# build, so do it at most once per user, and only if it's actually missing.
if timeout 90 dbt show --inline "select count(*) as n from {{ ref('CustomerMgmt') }}" --target "$TARGET" --target-path "$TP" >> "$LOG" 2>&1; then
  log "preflight: CustomerMgmt already present"
else
  log "preflight: CustomerMgmt MISSING -> building once (slow)"
  timeout 2400 dbt run --select CustomerMgmt --target "$TARGET" --target-path "$TP" >> "$LOG" 2>&1
  rc=$?
  log "preflight: CustomerMgmt build finished rc=${rc}"
fi

START=$(date +%s)
i=0
while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
  i=$((i+1))
  M=${MODELS[$((RANDOM % ${#MODELS[@]}))]}
  S=${SMALL[$((RANDOM % ${#SMALL[@]}))]}
  ACT=$((RANDOM % 10))
  case $ACT in
    0) log "iter $i: run $M";                 timeout 200 dbt run --select "$M"  --target "$TARGET" --target-path "$TP" --exclude CustomerMgmt $SF >> "$LOG" 2>&1 ;;
    1) log "iter $i: run ${S}+ (downstream)"; timeout 200 dbt run --select "${S}+" --target "$TARGET" --target-path "$TP" --exclude CustomerMgmt $SF >> "$LOG" 2>&1 ;;
    2) Q=$((RANDOM % 3))
       case $Q in
         0) QRY="select count(*) as n from {{ ref('$M') }}" ;;
         1) QRY="select count(*) as row_count, current_timestamp() as queried_at from {{ ref('$M') }}" ;;
         2) QRY="with t as (select * from {{ ref('$M') }}) select count(*) as n from t" ;;
       esac
       log "iter $i: inline ad-hoc query on $M"
       timeout 120 dbt show --inline "$QRY" --target "$TARGET" --target-path "$TP" >> "$LOG" 2>&1 ;;
    3) log "iter $i: compile $M";             timeout 120 dbt compile --select "$M" --target "$TARGET" --target-path "$TP" >> "$LOG" 2>&1 ;;
    4) log "iter $i: run $M $S (multi-model)"; timeout 200 dbt run --select "$M" "$S" --target "$TARGET" --target-path "$TP" --exclude CustomerMgmt $SF >> "$LOG" 2>&1 ;;
    5) log "iter $i: test $S";                timeout 150 dbt test --select "$S" --target "$TARGET" --target-path "$TP" >> "$LOG" 2>&1 ;;
    6) log "iter $i: build $S";               timeout 200 dbt build --select "$S" --target "$TARGET" --target-path "$TP" --exclude CustomerMgmt $SF >> "$LOG" 2>&1 ;;
    7) # small safe edit to THIS user's own model, then rerun
       RV=$((RANDOM % 1000)); SRC=${SMALL[$((RANDOM % ${#SMALL[@]}))]}
       cat > "$AGG" <<SQL
{{ config(materialized='table') }}
-- dynamic aggregate for user${USER_N}, rev ${i}/${RV} @ $(date +%s)
select
    '${SRC}'            as source_model,
    count(*)            as row_count,
    ${RV}               as rev_marker,
    current_timestamp() as built_at
from {{ ref('${SRC}') }}
SQL
       if [ "$NOSTATE" = "1" ]; then
         log "iter $i: edit agg_user${USER_N}_dyn + run (nostate)"
         timeout 200 dbt run --select "agg_user${USER_N}_dyn" --target "$TARGET" --target-path "$TP" $SF >> "$LOG" 2>&1
       else
         log "iter $i: edit agg_user${USER_N}_dyn + run state:modified+ (STATE)"
         timeout 200 dbt run --select "state:modified+" --target "$TARGET" --target-path "$TP" --exclude CustomerMgmt >> "$LOG" 2>&1
       fi ;;
    8) log "iter $i: run +$S (upstream)";     timeout 200 dbt run --select "+$S" --target "$TARGET" --target-path "$TP" --exclude CustomerMgmt $SF >> "$LOG" 2>&1 ;;
    9) log "iter $i: full run --exclude CustomerMgmt"; timeout 200 dbt run --exclude CustomerMgmt --target "$TARGET" --target-path "$TP" $SF >> "$LOG" 2>&1 ;;
  esac
done
ELAPSED=$(( $(date +%s) - START ))
log "==== user${USER_N} DONE iters=${i} elapsed=${ELAPSED}s ===="
echo "user${USER_N} (${COHORT}) done: iters=${i} elapsed=${ELAPSED}s"
