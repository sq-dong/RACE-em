#!/usr/bin/env bash
# RACE ATC Fig.13 风格：KV block 大小 64B→8KB 对时延/吞吐的影响
# 使用 ser_cli_var_kv：key=16B (key_len=2)，value_len 扫描。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
scale_params

OUT_CSV="$RESULTS_DIR/race_varlen.csv"
echo "value_len,key_bytes,op,num_cli,load_num,num_op,run_mops,avg_lat_us,run_ms,scale" >"$OUT_CSV"

NCLI=$(echo "$CLIENT_SWEEP" | tr ' ' '\n' | sort -n | tail -1)
# 大 value 时缩小 load，避免 OOM
case "$SCALE" in
  smoke)  BASE_LOAD=$LOAD_NUM; BASE_OP=$NUM_OP ;;
  medium) BASE_LOAD=2000000; BASE_OP=200000 ;;
  paper)  BASE_LOAD=5000000; BASE_OP=500000 ;;
esac

for vlen in $VARLEN_SIZES; do
  # 粗略：总 payload 预算 ~32GiB
  load=$(python3 -c "
v=$vlen; base=$BASE_LOAD
cap=32*1024*1024*1024
need=base*(16+v+32)
print(max(10000, int(base * min(1.0, cap/need))))
")
  op=$(python3 -c "print(max(10000, int($BASE_OP * $load / $BASE_LOAD)))")

  set_varlen_and_rebuild "$vlen" 2
  start_server "$BIN_VAR"

  for opname in search insert; do
    if [[ "$opname" == search ]]; then
      fracs="0.0 1.0 0.0 0.0"
    else
      fracs="1.0 0.0 0.0 0.0"
    fi
    read -r fi fr fu fd <<<"$fracs"
    tag="v${vlen}_${opname}"
    log "=== race_varlen $tag load=$load ==="
    logfile="$RESULTS_DIR/logs/race_varlen_${tag}.log"
    if ! run_client_retry "$logfile" "$BIN_VAR" \
      --num_cli 1 --num_coro 1 \
      --load_num "$load" --num_op "$op" \
      --pattern_type 1 \
      --insert_frac "$fi" --read_frac "$fr" --update_frac "$fu" --delete_frac "$fd" \
      --read_size 64; then
      log "skip/fail $tag"
      continue
    fi
    if ! grep -q 'Run IOPS' "$logfile"; then
      log "skip/fail $tag (no Run IOPS)"
      continue
    fi
    eval "$(parse_client_log "$logfile")"
    avg_lat=$(python3 -c "print(float('${run_ms}' or 0)*1000.0/float('$op'))")
    csv_row "$OUT_CSV" "$vlen" 16 "$opname" 1 "$load" "$op" "${run_mops:-}" "$avg_lat" "${run_ms:-}" "$SCALE"
  done
  stop_server
done

# 恢复默认 4096，避免污染后续手工实验
set_varlen_and_rebuild 4096 2 || true

log "race_varlen done -> $OUT_CSV"
