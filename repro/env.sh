#!/usr/bin/env bash
# Dual-node repro: memserver16 (memory) + bfhost_72 (client)
# IB datapath: 10.10.1.16/mlx5_2  <->  10.10.1.72/mlx5_0
# shellcheck shell=bash
set -euo pipefail

REPRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$REPRO_DIR/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$REPRO_DIR/results}"
FIGURES_DIR="${FIGURES_DIR:-$RESULTS_DIR/figures}"
mkdir -p "$RESULTS_DIR" "$FIGURES_DIR" "$RESULTS_DIR/logs"

# ---- cluster (memserver16 + bfhost_72) ----
export SRV_HOST="${SRV_HOST:-local}"
export CLT_HOST="${CLT_HOST:-bfhost_72}"
# TCP handshake over IPoIB; server binds INADDR_ANY
export SRV_IP="${SRV_IP:-10.10.1.16}"
# InfiniBand: both Active ports expose GID index 0 only (not RoCE)
export GID_IDX="${GID_IDX:-0}"
export SRV_IBDEV="${SRV_IBDEV:-mlx5_2}"   # memserver16 ibs5f0 Up
export CLT_IBDEV="${CLT_IBDEV:-mlx5_0}"   # bfhost_72  ibs2f0 Up
export SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=12 -o StrictHostKeyChecking=no}"

# Source on memserver16; client tree under /tmp (home often full)
export SRV_SRC="${SRV_SRC:-$ROOT}"
export CLT_SRC="${CLT_SRC:-/tmp/dongshuqi/SepHash}"
export SRV_BUILD="${SRV_BUILD:-$SRV_SRC/build}"
export CLT_BUILD="${CLT_BUILD:-$CLT_SRC/build}"

export BIN_FIXED="${BIN_FIXED:-ser_cli}"
export BIN_VAR="${BIN_VAR:-ser_cli_var_kv}"

# Memory pool bytes. Without ENABLE_HUGEPAGE uses posix_memalign.
# Paper suggests >=80GiB; lower if the machine is tight.
export MEM_SIZE="${MEM_SIZE:-$((80 * 1024 * 1024 * 1024))}"

# smoke | medium | paper
export SCALE="${SCALE:-medium}"

# Space-separated experiment list. Default: RACE only.
# Add sephash_insert sephash_hybrid for SepHash-style baselines.
export EXPTS="${EXPTS:-race_tput race_hybrid race_latency race_ycsb race_varlen}"

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

pick_cxx() {
  if [[ -x /usr/bin/g++-13 ]]; then
    echo /usr/bin/g++-13
  elif [[ -x /usr/bin/g++-11 ]]; then
    echo /usr/bin/g++-11
  else
    echo g++
  fi
}

scale_params() {
  # Exports LOAD_NUM / NUM_OP / CLIENT_SWEEP / CORO
  # Override with: CLIENT_SWEEP_OVERRIDE / LOAD_NUM_OVERRIDE / NUM_OP_OVERRIDE
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
      export CLIENT_SWEEP="1 2 4 8 16 32 48 64"
      export CORO=1
      export VARLEN_SIZES="64 256 512 1024 4096"
      export HYBRID_RATIOS="0.1 0.3 0.5 0.7 0.9"
      export YCSB_LOAD=10000000
      export YCSB_OP=1000000
      ;;
    paper)
      # Align RACE/SepHash: load 1e8, run 1e7; client axis to 128
      # (bfhost_72 has 96 logical cores; 128 slightly oversubscribes)
      export LOAD_NUM=100000000
      export NUM_OP=10000000
      export CLIENT_SWEEP="1 2 4 8 16 32 64 128"
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
  [[ -n "${CLIENT_SWEEP_OVERRIDE:-}" ]] && export CLIENT_SWEEP="$CLIENT_SWEEP_OVERRIDE"
  [[ -n "${LOAD_NUM_OVERRIDE:-}" ]] && export LOAD_NUM="$LOAD_NUM_OVERRIDE"
  [[ -n "${NUM_OP_OVERRIDE:-}" ]] && export NUM_OP="$NUM_OP_OVERRIDE"
  log "SCALE=$SCALE LOAD_NUM=$LOAD_NUM NUM_OP=$NUM_OP clients=[$CLIENT_SWEEP] MEM_SIZE=$MEM_SIZE"
  log "cluster SRV_IP=$SRV_IP CLT_HOST=$CLT_HOST SRV_IBDEV=$SRV_IBDEV CLT_IBDEV=$CLT_IBDEV GID_IDX=$GID_IDX"
}
