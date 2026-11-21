#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
scale_params

OUT_CSV="$RESULTS_DIR/sephash_hybrid.csv"
echo "insert_search_label,insert_frac,search_frac,num_cli,load_num,num_op,run_mops,run_ms,scale" >"$OUT_CSV"

NCLI=$(echo "$CLIENT_SWEEP" | tr ' ' '\n' | sort -n | tail -1)

build_local "$BIN_FIXED"
sync_and_build_client "$BIN_FIXED"
trap 'stop_server' EXIT

for pair in 1:9 3:7 5:5 7:3 9:1; do
  ins=${pair%%:*}; sea=${pair##*:}
  ifrac=$(python3 -c "print(round($ins/($ins+$sea), 10))")
  sfrac=$(python3 -c "print(round($sea/($ins+$sea), 10))")
  tag="r${pair}"
  log "=== sephash_hybrid $tag ==="
  start_server "$BIN_FIXED"
  logfile="$RESULTS_DIR/logs/sephash_hybrid_${tag}.log"
  run_client_retry "$logfile" "$BIN_FIXED" \
    --num_cli "$NCLI" --num_coro "$CORO" \
    --load_num "$LOAD_NUM" --num_op "$NUM_OP" \
    --pattern_type 2 \
    --insert_frac "$ifrac" --read_frac "$sfrac" --update_frac 0.0 --delete_frac 0.0 \
    --read_size 64
  eval "$(parse_client_log "$logfile")"
  csv_row "$OUT_CSV" "$pair" "$ifrac" "$sfrac" "$NCLI" "$LOAD_NUM" "$NUM_OP" "${run_mops:-}" "${run_ms:-}" "$SCALE"
done

log "sephash_hybrid done -> $OUT_CSV"
