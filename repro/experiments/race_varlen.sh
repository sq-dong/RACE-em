#!/usr/bin/env bash
# RACE ATC Fig.13: KV block 64B→8KB; Insertion / Search / Deletion / Update
# Uses ser_cli_var_kv: key=16B (key_len=2), sweep value_len.
# RESUME=1: keep existing (value_len,op) rows; fill missing only
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
scale_params

OUT_CSV="$RESULTS_DIR/race_varlen.csv"
RESUME="${RESUME:-0}"

if [[ "$RESUME" == "1" && -f "$OUT_CSV" ]]; then
  log "RESUME=1 keep existing $OUT_CSV"
else
  echo "value_len,key_bytes,op,num_cli,load_num,num_op,run_mops,avg_lat_us,run_ms,scale" >"$OUT_CSV"
fi

have_point() {
  local vlen=$1 opname=$2
  [[ -f "$OUT_CSV" ]] || return 1
  awk -F, -v v="$vlen" -v op="$opname" 'NR>1 && $1==v && $3==op {found=1} END{exit !found}' "$OUT_CSV"
}

# Fixed 1 client (KV size effect, not scalability)
# Shrink load for large values to avoid OOM
case "$SCALE" in
  smoke)  BASE_LOAD=$LOAD_NUM; BASE_OP=$NUM_OP ;;
  medium) BASE_LOAD=2000000; BASE_OP=200000 ;;
  paper)  BASE_LOAD=5000000; BASE_OP=500000 ;;
esac

# Paper Fig.13 order: Insertion, Search, Deletion, Update
OPS=(insert search delete update)
frac_for() {
  case "$1" in
    insert) echo "1.0 0.0 0.0 0.0" ;;
    search) echo "0.0 1.0 0.0 0.0" ;;
    delete) echo "0.0 0.0 0.0 1.0" ;;
    update) echo "0.0 0.0 1.0 0.0" ;;
  esac
}

for vlen in $VARLEN_SIZES; do
  # Rough payload budget ~32GiB
  load=$(python3 -c "
v=$vlen; base=$BASE_LOAD
cap=32*1024*1024*1024
need=base*(16+v+32)
print(max(10000, int(base * min(1.0, cap/need))))
")
  op=$(python3 -c "print(max(10000, int($BASE_OP * $load / $BASE_LOAD)))")

  # Skip rebuild if all four ops for this size already exist
  need_any=0
  for opname in "${OPS[@]}"; do
    if ! have_point "$vlen" "$opname"; then need_any=1; break; fi
  done
  if [[ "$need_any" -eq 0 ]]; then
    log "=== race_varlen v${vlen} SKIP (all 4 ops in CSV) ==="
    continue
  fi

  set_varlen_and_rebuild "$vlen" 2

  for opname in "${OPS[@]}"; do
    if have_point "$vlen" "$opname"; then
      log "=== race_varlen v${vlen}_${opname} SKIP (already in CSV) ==="
      continue
    fi
    read -r fi fr fu fd <<<"$(frac_for "$opname")"
    tag="v${vlen}_${opname}"
    log "=== race_varlen $tag load=$load ==="
    # Restart server per point: client always loads; reuse would collide keys
    start_server "$BIN_VAR"
    logfile="$RESULTS_DIR/logs/race_varlen_${tag}.log"
    if ! run_client_retry "$logfile" "$BIN_VAR" \
      --num_cli 1 --num_coro 1 \
      --load_num "$load" --num_op "$op" \
      --pattern_type 1 \
      --insert_frac "$fi" --read_frac "$fr" --update_frac "$fu" --delete_frac "$fd" \
      --read_size 64; then
      log "skip/fail $tag"
      stop_server || true
      continue
    fi
    if ! grep -q 'Run IOPS' "$logfile"; then
      log "skip/fail $tag (no Run IOPS)"
      stop_server || true
      continue
    fi
    eval "$(parse_client_log "$logfile")"
    avg_lat=$(python3 -c "print(float('${run_ms}' or 0)*1000.0/float('$op'))")
    csv_row "$OUT_CSV" "$vlen" 16 "$opname" 1 "$load" "$op" "${run_mops:-}" "$avg_lat" "${run_ms:-}" "$SCALE"
    stop_server || true
  done
done

# Restore default 4096 so later manual runs are not polluted
set_varlen_and_rebuild 4096 2 || true

log "race_varlen done -> $OUT_CSV"
