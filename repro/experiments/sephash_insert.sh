#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
scale_params

OUT_CSV="$RESULTS_DIR/sephash_insert.csv"
echo "num_cli,num_coro,load_num,num_op,load_mops,load_ms,run_mops,entry_util,scale" >"$OUT_CSV"

build_local "$BIN_FIXED"
sync_and_build_client "$BIN_FIXED"
trap 'stop_server' EXIT

for ncli in $CLIENT_SWEEP; do
  tag="c${ncli}"
  log "=== sephash_insert $tag ==="
  start_server "$BIN_FIXED"
  logfile="$RESULTS_DIR/logs/sephash_insert_${tag}.log"
  run_client_retry "$logfile" "$BIN_FIXED" \
    --num_cli "$ncli" --num_coro "$CORO" \
    --load_num "$LOAD_NUM" --num_op "$NUM_OP" \
    --pattern_type 1 \
    --insert_frac 1.0 --read_frac 0.0 --update_frac 0.0 --delete_frac 0.0 \
    --read_size 64
  eval "$(parse_client_log "$logfile")"
  csv_row "$OUT_CSV" "$ncli" "$CORO" "$LOAD_NUM" "$NUM_OP" "${load_mops:-}" "${load_ms:-}" "${run_mops:-}" "${entry_util:-}" "$SCALE"
done

log "sephash_insert done -> $OUT_CSV"
