#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
scale_params

OUT_CSV="$RESULTS_DIR/race_latency.csv"
echo "op,load_num,num_op,entry_util,avg_lat_us,run_ms,run_mops,scale" >"$OUT_CSV"

case "$SCALE" in
  smoke)  LOADS="50000 100000 200000" ;;
  medium) LOADS="2000000 5000000 10000000 20000000" ;;
  paper)  LOADS="20000000 40000000 60000000 80000000 100000000" ;;
esac

case "$SCALE" in
  smoke)  LAT_OP=20000 ;;
  medium) LAT_OP=200000 ;;
  paper)  LAT_OP=1000000 ;;
esac

build_local "$BIN_FIXED"
sync_and_build_client "$BIN_FIXED"
trap 'stop_server' EXIT

frac_for() {
  case "$1" in
    insert) echo "1.0 0.0 0.0 0.0" ;;
    search) echo "0.0 1.0 0.0 0.0" ;;
    update) echo "0.0 0.0 1.0 0.0" ;;
    delete) echo "0.0 0.0 0.0 1.0" ;;
  esac
}

for load in $LOADS; do
  for op in insert search update delete; do
    read -r fi fr fu fd <<<"$(frac_for "$op")"
    tag="${op}_L${load}"
    log "=== race_latency $tag ==="
    start_server "$BIN_FIXED"
    logfile="$RESULTS_DIR/logs/race_latency_${tag}.log"
    run_client_retry "$logfile" "$BIN_FIXED" \
      --num_cli 1 --num_coro 1 \
      --load_num "$load" --num_op "$LAT_OP" \
      --pattern_type 1 \
      --insert_frac "$fi" --read_frac "$fr" --update_frac "$fu" --delete_frac "$fd" \
      --read_size 64
    eval "$(parse_client_log "$logfile")"
    avg_lat=$(python3 -c "print(float('${run_ms}' or 0)*1000.0/float('$LAT_OP'))")
    csv_row "$OUT_CSV" "$op" "$load" "$LAT_OP" "${entry_util:-}" "$avg_lat" "${run_ms:-}" "${run_mops:-}" "$SCALE"
  done
done

log "race_latency done -> $OUT_CSV"
