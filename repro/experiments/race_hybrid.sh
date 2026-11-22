#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
scale_params

OUT_CSV="$RESULTS_DIR/race_hybrid.csv"
echo "search_frac,insert_frac,num_cli,num_coro,load_num,num_op,run_mops,run_ms,entry_util,scale" >"$OUT_CSV"

NCLI=$(echo "$CLIENT_SWEEP" | tr ' ' '\n' | sort -n | tail -1)

build_local "$BIN_FIXED"
sync_and_build_client "$BIN_FIXED"
trap 'stop_server' EXIT

for sfrac in $HYBRID_RATIOS; do
  ifrac=$(python3 -c "print(round(1.0 - float('$sfrac'), 10))")
  tag="s${sfrac}_i${ifrac}_c${NCLI}"
  log "=== race_hybrid $tag ==="
  start_server "$BIN_FIXED"
  logfile="$RESULTS_DIR/logs/race_hybrid_${tag}.log"
  run_client_retry "$logfile" "$BIN_FIXED" \
    --num_cli "$NCLI" --num_coro "$CORO" \
    --load_num "$LOAD_NUM" --num_op "$NUM_OP" \
    --pattern_type 2 \
    --insert_frac "$ifrac" --read_frac "$sfrac" --update_frac 0.0 --delete_frac 0.0 \
    --read_size 64
  eval "$(parse_client_log "$logfile")"
  csv_row "$OUT_CSV" "$sfrac" "$ifrac" "$NCLI" "$CORO" "$LOAD_NUM" "$NUM_OP" "${run_mops:-}" "${run_ms:-}" "${entry_util:-}" "$SCALE"
done

log "race_hybrid done -> $OUT_CSV"
