#!/usr/bin/env bash
# RACE ATC Fig.11 style: throughput vs client threads (insert/search/update/delete)
# RESUME=1: keep existing CSV rows; skip completed (op,num_cli) points
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
scale_params

OUT_CSV="$RESULTS_DIR/race_tput.csv"
RESUME="${RESUME:-0}"

if [[ "$RESUME" == "1" && -f "$OUT_CSV" ]]; then
  log "RESUME=1 keep existing $OUT_CSV"
else
  {
    echo "op,num_cli,num_coro,load_num,num_op,run_mops,run_ms,entry_util,scale"
  } >"$OUT_CSV"
fi

have_point() {
  local op=$1 ncli=$2
  [[ -f "$OUT_CSV" ]] || return 1
  awk -F, -v op="$op" -v n="$ncli" 'NR>1 && $1==op && $2==n {found=1} END{exit !found}' "$OUT_CSV"
}

build_local "$BIN_FIXED"
sync_and_build_client "$BIN_FIXED"
trap 'stop_server' EXIT

OPS=(insert search update delete)
frac_for() {
  case "$1" in
    insert) echo "1.0 0.0 0.0 0.0" ;;
    search) echo "0.0 1.0 0.0 0.0" ;;
    update) echo "0.0 0.0 1.0 0.0" ;;
    delete) echo "0.0 0.0 0.0 1.0" ;;
  esac
}

for op in "${OPS[@]}"; do
  read -r fi fr fu fd <<<"$(frac_for "$op")"
  for ncli in $CLIENT_SWEEP; do
    tag="${op}_c${ncli}"
    if have_point "$op" "$ncli"; then
      log "=== race_tput $tag SKIP (already in CSV) ==="
      continue
    fi
    log "=== race_tput $tag ==="
    # Restart server per point to avoid stale accept / port issues
    start_server "$BIN_FIXED"
    logfile="$RESULTS_DIR/logs/race_tput_${tag}.log"
    run_client_retry "$logfile" "$BIN_FIXED" \
      --num_cli "$ncli" --num_coro "$CORO" \
      --load_num "$LOAD_NUM" --num_op "$NUM_OP" \
      --pattern_type 2 \
      --insert_frac "$fi" --read_frac "$fr" --update_frac "$fu" --delete_frac "$fd" \
      --read_size 64
    eval "$(parse_client_log "$logfile")"
    csv_row "$OUT_CSV" "$op" "$ncli" "$CORO" "$LOAD_NUM" "$NUM_OP" "${run_mops:-}" "${run_ms:-}" "${entry_util:-}" "$SCALE"
  done
done

log "race_tput done -> $OUT_CSV"
