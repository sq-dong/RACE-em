#!/usr/bin/env bash
# RACE ATC Fig.11 风格：吞吐 vs client 线程数（insert/search/update/delete 四分图）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
scale_params

OUT_CSV="$RESULTS_DIR/race_tput.csv"
# 每次全量重跑时覆盖旧 CSV（保留表头）
{
  echo "op,num_cli,num_coro,load_num,num_op,run_mops,run_ms,entry_util,scale"
} >"$OUT_CSV"

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
    log "=== race_tput $tag ==="
    # 每个点重启 server，避免长跑后 accept 僵死 / 端口异常
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
