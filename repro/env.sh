#!/usr/bin/env bash
# SepHash/RACE 双机复现环境：server02 (memory) + server03 (client)
# shellcheck shell=bash
set -euo pipefail

REPRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$REPRO_DIR/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$REPRO_DIR/results}"
FIGURES_DIR="${FIGURES_DIR:-$RESULTS_DIR/figures}"
mkdir -p "$RESULTS_DIR" "$FIGURES_DIR" "$RESULTS_DIR/logs"

# ---- 集群 ----
export SRV_HOST="${SRV_HOST:-local}"
export CLT_HOST="${CLT_HOST:-server03}"
export SRV_IP="${SRV_IP:-10.0.0.20}"
export GID_IDX="${GID_IDX:-3}"
export SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=no}"

# server02 本地路径 / server03 因 /home 满，默认放 /tmp
export SRV_SRC="${SRV_SRC:-$ROOT}"
export CLT_SRC="${CLT_SRC:-/tmp/dsq/SepHash}"
export SRV_BUILD="${SRV_BUILD:-$SRV_SRC/build}"
export CLT_BUILD="${CLT_BUILD:-$CLT_SRC/build}"

export BIN_FIXED="${BIN_FIXED:-ser_cli}"
export BIN_VAR="${BIN_VAR:-ser_cli_var_kv}"

# 内存池大小（字节）。paper 建议 ≥80GiB；机器紧张可降。
export MEM_SIZE="${MEM_SIZE:-$((80 * 1024 * 1024 * 1024))}"

# smoke | medium | paper
export SCALE="${SCALE:-medium}"

# 实验列表（空格分隔）。默认跑全部可复现项。
export EXPTS="${EXPTS:-race_tput race_hybrid race_latency race_ycsb race_varlen sephash_insert sephash_hybrid}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

remote() {
  local host=$1; shift
  if [[ -z "$host" || "$host" == "local" || "$host" == "localhost" ]]; then
    bash -lc "$*"
  else
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$host" "$*"
  fi
}

scale_params() {
  # 导出 LOAD_NUM / NUM_OP / CLIENT_SWEEP / CORO
  case "$SCALE" in
    smoke)
      export LOAD_NUM=100000
      export NUM_OP=20000
      export CLIENT_SWEEP="1 2 4"
      export CORO=1
      export VARLEN_SIZES="64 256 1024"
      export HYBRID_RATIOS="0.1 0.5 0.9"   # search fraction; insert = 1-search
      export YCSB_LOAD=100000
      export YCSB_OP=20000
      ;;
    medium)
      export LOAD_NUM=10000000
      export NUM_OP=1000000
      export CLIENT_SWEEP="1 2 4 8 16 32"
      export CORO=1
      export VARLEN_SIZES="64 256 512 1024 4096"
      export HYBRID_RATIOS="0.1 0.3 0.5 0.7 0.9"
      export YCSB_LOAD=10000000
      export YCSB_OP=1000000
      ;;
    paper)
      # 对齐 RACE/SepHash：load 1e8、run 1e7；client 扫到 64（双机单 client 机，论文到 128）
      export LOAD_NUM=100000000
      export NUM_OP=10000000
      export CLIENT_SWEEP="1 2 4 8 16 32 64"
      export CORO=1
      export VARLEN_SIZES="64 128 256 512 1024 2048 4096 8192"
      export HYBRID_RATIOS="0.1 0.3 0.5 0.7 0.9"
      export YCSB_LOAD=100000000
      export YCSB_OP=10000000
      ;;
    *)
      log "unknown SCALE=$SCALE (use smoke|medium|paper)"
      exit 1
      ;;
  esac
  log "SCALE=$SCALE LOAD_NUM=$LOAD_NUM NUM_OP=$NUM_OP clients=[$CLIENT_SWEEP] MEM_SIZE=$MEM_SIZE"
}
