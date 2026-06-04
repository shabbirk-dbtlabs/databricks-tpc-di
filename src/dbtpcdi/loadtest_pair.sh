#!/usr/bin/env bash
# Barrier-synced PAIR driver: runs the SAME operation on a state twin (user P) and a
# no-state twin (user P+25) CONCURRENTLY, waits for BOTH to finish (no timeout slicing),
# then advances. The faster twin's wait at the barrier == capacity it got back.
#
# Args: PAIR(1..25)  STATE_PROJDIR  NOSTATE_PROJDIR  LOGDIR  [DURATION=1800]  [SAFE=2400]
set -uo pipefail

PAIR="$1"; SDIR="$2"; NDIR="$3"; LOGDIR="$4"
DURATION="${5:-1800}"; SAFE="${6:-2400}"        # SAFE = generous per-op hang guard only
SU="$PAIR"; NU=$(( PAIR + 25 ))
ST="test_user${SU}"; NT="test_user${NU}"
STP="target/user${SU}"; NTP="target/user${NU}"
mkdir -p "$LOGDIR"
SLOG="${LOGDIR}/user${SU}.log";  NLOG="${LOGDIR}/user${NU}.log"
SMET="${LOGDIR}/user${SU}.metrics"; NMET="${LOGDIR}/user${NU}.metrics"
STMP="/tmp/lt_s_${PAIR}.out"; NTMP="/tmp/lt_n_${PAIR}.out"

RANDOM=$PAIR                                     # one RNG per pair -> deterministic sequence
MODELS=(DimBroker DimDate DimTime TradeType StatusType TaxRate Industry \
        DimCompany DimSecurity DimAccount DimCustomer Prospect BatchDate \
        Financial FinWire FactWatches FactCashBalances FactHoldings \
        FactMarketHistory DimTrade)
SMALL=(DimBroker DimDate DimTime TradeType StatusType TaxRate Industry DimCompany DimSecurity)

cb(){ grep -E 'Succeeded \[.*\] model ' "$1" 2>/dev/null | grep -vc '(ephemeral)'; }   # built
cr(){ grep -cE 'Reused \[.*\] model ' "$1" 2>/dev/null; }                              # reused

echo "==== pair${PAIR}: state=user${SU} nostate=user${NU} START $(date) ====" | tee -a "$SLOG" >> "$NLOG"
: > "$SMET"; : > "$NMET"

START=$(date +%s); i=0
while [ $(( $(date +%s) - START )) -lt "$DURATION" ]; do
  i=$((i+1))
  M=${MODELS[$((RANDOM % ${#MODELS[@]}))]}
  S=${SMALL[$((RANDOM % ${#SMALL[@]}))]}
  ACT=$((RANDOM % 10))
  # CORE_S / CORE_N = dbt args excluding --target/--target-path (nostate adds --no-manage-state on materializing ops)
  case $ACT in
    0) OP="run $M";            CORE_S=(run --select "$M" --exclude CustomerMgmt);            CORE_N=(run --select "$M" --exclude CustomerMgmt --no-manage-state) ;;
    1) OP="run ${S}+";         CORE_S=(run --select "${S}+" --exclude CustomerMgmt);         CORE_N=(run --select "${S}+" --exclude CustomerMgmt --no-manage-state) ;;
    2) Q=$((RANDOM % 3)); case $Q in
         0) QRY="select count(*) as n from {{ ref('$M') }}" ;;
         1) QRY="select count(*) as rc, current_timestamp() as t from {{ ref('$M') }}" ;;
         2) QRY="with t as (select * from {{ ref('$M') }}) select count(*) as n from t" ;; esac
       OP="inline $M";         CORE_S=(show --inline "$QRY");                                CORE_N=(show --inline "$QRY") ;;
    3) OP="compile $M";        CORE_S=(compile --select "$M");                               CORE_N=(compile --select "$M") ;;
    4) OP="run $M $S (multi)"; CORE_S=(run --select "$M" "$S" --exclude CustomerMgmt);       CORE_N=(run --select "$M" "$S" --exclude CustomerMgmt --no-manage-state) ;;
    5) OP="test $S";           CORE_S=(test --select "$S");                                  CORE_N=(test --select "$S") ;;
    6) OP="build $S";          CORE_S=(build --select "$S" --exclude CustomerMgmt);          CORE_N=(build --select "$S" --exclude CustomerMgmt --no-manage-state) ;;
    7) RV=$((RANDOM % 1000)); SRC=${SMALL[$((RANDOM % ${#SMALL[@]}))]}
       for D in "$SDIR" "$NDIR"; do
         UU=$SU; [ "$D" = "$NDIR" ] && UU=$NU
         cat > "$D/Databricks_CSV/models/main/agg_user${UU}_dyn.sql" <<SQL
{{ config(materialized='table') }}
-- dynamic aggregate user${UU} rev ${i}/${RV} @ $(date +%s)
select '${SRC}' as source_model, count(*) as row_count, ${RV} as rev_marker, current_timestamp() as built_at
from {{ ref('${SRC}') }}
SQL
       done
       # Same selection for both: the edited agg model AND its upstream (+agg).
       # Managed state reuses the unchanged upstream and builds only the changed agg;
       # no-state rebuilds the agg AND all of its upstream. This is the reuse story.
       OP="edit+run agg";      CORE_S=(run --select "+agg_user${SU}_dyn" --exclude CustomerMgmt); CORE_N=(run --select "+agg_user${NU}_dyn" --exclude CustomerMgmt --no-manage-state) ;;
    8) OP="run +$S";           CORE_S=(run --select "+$S" --exclude CustomerMgmt);           CORE_N=(run --select "+$S" --exclude CustomerMgmt --no-manage-state) ;;
    9) OP="full run";          CORE_S=(run --exclude CustomerMgmt);                          CORE_N=(run --exclude CustomerMgmt --no-manage-state) ;;
  esac

  # launch both twins concurrently, each timing itself; barrier = wait for BOTH
  ( cd "$SDIR"; t=$(date +%s); timeout "$SAFE" dbt "${CORE_S[@]}" --target "$ST" --target-path "$STP" > "$STMP" 2>&1; echo $(( $(date +%s) - t )) > "${STMP}.dur" ) &
  sp=$!
  ( cd "$NDIR"; t=$(date +%s); timeout "$SAFE" dbt "${CORE_N[@]}" --target "$NT" --target-path "$NTP" > "$NTMP" 2>&1; echo $(( $(date +%s) - t )) > "${NTMP}.dur" ) &
  np=$!
  wait "$sp"; wait "$np"

  bs=$(cat "${STMP}.dur" 2>/dev/null || echo 0); bn=$(cat "${NTMP}.dur" 2>/dev/null || echo 0)
  sbu=$(cb "$STMP"); sre=$(cr "$STMP"); stot=$((sbu+sre))
  nbu=$(cb "$NTMP"); nre=$(cr "$NTMP"); ntot=$((nbu+nre))
  ws=$(( bn - bs )); [ $ws -lt 0 ] && ws=0      # state twin's wait at barrier (freed time)
  wn=$(( bs - bn )); [ $wn -lt 0 ] && wn=0
  opw=${OP%% *}
  echo "METRIC user=${SU} cohort=state   iter=${i} op=${opw} rc=0 busy=${bs} idle=${ws} models_total=${stot} models_reused=${sre}" >> "$SMET"
  echo "METRIC user=${NU} cohort=nostate iter=${i} op=${opw} rc=0 busy=${bn} idle=${wn} models_total=${ntot} models_reused=${nre}" >> "$NMET"
  cat "$STMP" >> "$SLOG"; echo "[$(date '+%H:%M:%S')] iter ${i}: ${OP} | state busy=${bs}s reuse=${sre}/${stot} wait=${ws}s" >> "$SLOG"
  cat "$NTMP" >> "$NLOG"; echo "[$(date '+%H:%M:%S')] iter ${i}: ${OP} | nostate busy=${bn}s built=${nbu}/${ntot} wait=${wn}s" >> "$NLOG"
done
echo "pair${PAIR} done: iters=${i} elapsed=$(( $(date +%s) - START ))s"
