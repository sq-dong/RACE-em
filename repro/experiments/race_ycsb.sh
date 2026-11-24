#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
scale_params

OUT_CSV="$RESULTS_DIR/race_ycsb.csv"
echo "workload,pattern,insert_frac,read_frac,update_frac,delete_frac,num_cli,load_num,num_op,run_mops,run_ms,entry_util,scale" >"$OUT_CSV"

NCLI=$(echo "$CLIENT_SWEEP" | tr ' ' '\n' | sort -n | tail -1)

build_local "$BIN_FIXED"
sync_and_build_client "$BIN_FIXED"
trap 'stop_server' EXIT

run_one() {
  local name=$1 pat=$2 fi=$3 fr=$4 fu=$5 fd=$6
  log "=== race_ycsb $name ==="
  start_server "$BIN_FIXED"
  local logfile="$RESULTS_DIR/logs/race_ycsb_${name}.log"
  if ! run_client_retry "$logfile" "$BIN_FIXED" \
    --num_cli "$NCLI" --num_coro "$CORO" \
    --load_num "$YCSB_LOAD" --num_op "$YCSB_OP" \
    --pattern_type "$pat" \
    --insert_frac "$fi" --read_frac "$fr" --update_frac "$fu" --delete_frac "$fd" \
    --read_size 64; then
    log "race_ycsb $name failed (see $logfile)"
    return 0
  fi
  eval "$(parse_client_log "$logfile")"
  csv_row "$OUT_CSV" "$name" "$pat" "$fi" "$fr" "$fu" "$fd" "$NCLI" "$YCSB_LOAD" "$YCSB_OP" "${run_mops:-}" "${run_ms:-}" "${entry_util:-}" "$SCALE"
}

# Matches ser_cli.sh / SepHash Fig.17 comments:
# A: 50% insert + 50% read (zipf)；B: 95% read + 5% update；C: 100% read；D: 5% insert + 95% read (latest)
run_one A 2 0.5 0.5 0.0 0.0
run_one B 2 0.0 0.95 0.05 0.0
run_one C 2 0.0 1.0 0.0 0.0
run_one D 3 0.05 0.95 0.0 0.0

log "race_ycsb done -> $OUT_CSV"
