#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers: sync, build, start/stop server, run client, parse logs
# Cluster: memserver16 (mlx5_2) + bfhost_72 (mlx5_0)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

SERVER_PID_FILE="${RESULTS_DIR}/.server.pid"
SERVER_KEEPER_PID_FILE="${RESULTS_DIR}/.server.keeper.pid"
SERVER_FIFO="${RESULTS_DIR}/.server.stdin"
SERVER_LOG="${RESULTS_DIR}/logs/server.log"

ensure_race_sources() {
  # Ensure local tree uses RACE ClientType (idempotent)
  local f
  for f in "$SRV_SRC/test/ser_cli.cc" "$SRV_SRC/test/ser_cli_var_kv.cc"; do
    if ! grep -q 'using ClientType = RACE::Client;' "$f"; then
      log "switching $f to RACE::"
      sed -i \
        -e 's/using ClientType = SEPHASH::Client;/using ClientType = RACE::Client;/' \
        -e 's/using ServerType = SEPHASH::Server;/using ServerType = RACE::Server;/' \
        -e 's/using Slice = SEPHASH::Slice;/using Slice = RACE::Slice;/' \
        "$f"
    fi
  done
}

# Pin Server/Client to Active IB devices on this cluster (idempotent)
pin_ib_devices_local() {
  local srv_dev="${SRV_IBDEV}"
  local clt_dev="${CLT_IBDEV}"
  # RACE/other Server: nullptr picks mlx5_0(Down); must set explicitly
  while IFS= read -r -d '' f; do
    sed -i -E \
      -e "s/dev\(nullptr, 1, config\.gid_idx\)/dev(\"${srv_dev}\", 1, config.gid_idx)/g" \
      -e "s/dev\(\"(mlx5_[0-9]+)\", 1, config\.gid_idx\)/dev(\"${srv_dev}\", 1, config.gid_idx)/g" \
      "$f"
  done < <(find "$SRV_SRC/src" -name '*.cc' -print0)
  # Client NIC hard-coded (runs on bfhost_72)
  sed -i -E \
    "s/rdma_dev dev\(\"(mlx5_[0-9]+)\"/rdma_dev dev(\"${clt_dev}\"/g" \
    "$SRV_SRC/test/ser_cli.cc" "$SRV_SRC/test/ser_cli_var_kv.cc"
  # Allow up to 96+ clients (was ths[80])
  sed -i -E 's/std::thread ths\[[0-9]+\];/std::thread ths[128];/' \
    "$SRV_SRC/test/ser_cli.cc" "$SRV_SRC/test/ser_cli_var_kv.cc"
  log "pin IB: server=$srv_dev client=$clt_dev"
}

ensure_cmake_fresh_if_compiler_changed() {
  local cxx want
  cxx="$(pick_cxx)"
  if [[ -f "$SRV_BUILD/CMakeCache.txt" ]]; then
    want="$(grep -E '^CMAKE_CXX_COMPILER:' "$SRV_BUILD/CMakeCache.txt" | head -1 || true)"
    if [[ -n "$want" && "$want" != *"$cxx"* ]]; then
      log "compiler changed -> wipe $SRV_BUILD"
      rm -rf "$SRV_BUILD"
    fi
  fi
}

build_local() {
  local targets="${1:-$BIN_FIXED $BIN_VAR}"
  ensure_race_sources
  pin_ib_devices_local
  ensure_cmake_fresh_if_compiler_changed
  mkdir -p "$SRV_BUILD"
  (
    cd "$SRV_BUILD"
    if [[ ! -f Makefile ]]; then
      cmake -DCMAKE_CXX_COMPILER="$(pick_cxx)" "$SRV_SRC"
    fi
    # shellcheck disable=SC2086
    make -j"$(nproc)" $targets
  )
  log "local build ok: $targets"
}

rsync_with_retry() {
  local try
  remote "$CLT_HOST" "mkdir -p '$CLT_SRC'"
  for try in 1 2 3 4 5; do
    log "rsync -> $CLT_HOST:$CLT_SRC (try $try)"
    if rsync -az --delete \
      --exclude build --exclude .git --exclude 'repro/results' \
      "$SRV_SRC/" "$CLT_HOST:$CLT_SRC/"; then
      return 0
    fi
    log "rsync failed (try $try), sleep $((try * 5))s"
    sleep $((try * 5))
  done
  log "rsync failed after retries"
  return 1
}

sync_and_build_client() {
  local targets="${1:-$BIN_FIXED $BIN_VAR}"
  if [[ "${SKIP_SYNC:-0}" == "1" ]]; then
    log "SKIP_SYNC=1: reuse existing $CLT_HOST:$CLT_BUILD/$BIN_FIXED (no rsync/rebuild)"
    remote "$CLT_HOST" "test -x '$CLT_BUILD/$BIN_FIXED'" || {
      log "missing client binary $CLT_BUILD/$BIN_FIXED"
      return 1
    }
    return 0
  fi
  rsync_with_retry || return 1

  local remote_sh="$RESULTS_DIR/.client_build.sh"
  cat >"$remote_sh" <<'REMOTE_EOF'
set -euo pipefail
CLT_SRC="$1"
CLT_IBDEV="$2"
TARGETS="$3"
cd "$CLT_SRC"
sed -i -E "s/rdma_dev dev\(\"(mlx5_[0-9]+)\"/rdma_dev dev(\"${CLT_IBDEV}\"/g" \
  test/ser_cli.cc test/ser_cli_var_kv.cc || true
sed -i -E 's/std::thread ths\[[0-9]+\];/std::thread ths[128];/' \
  test/ser_cli.cc test/ser_cli_var_kv.cc || true
if [[ -x /usr/bin/g++-13 ]]; then CXX_BIN=/usr/bin/g++-13
elif [[ -x /usr/bin/g++-11 ]]; then CXX_BIN=/usr/bin/g++-11
else CXX_BIN=g++
fi
for f in test/ser_cli.cc test/ser_cli_var_kv.cc; do
  sed -i \
    -e 's/using ClientType = SEPHASH::Client;/using ClientType = RACE::Client;/' \
    -e 's/using ServerType = SEPHASH::Server;/using ServerType = RACE::Server;/' \
    -e 's/using Slice = SEPHASH::Slice;/using Slice = RACE::Slice;/' \
    "$f"
done
rm -rf build
mkdir -p build && cd build
cmake -DCMAKE_CXX_COMPILER="${CXX_BIN}" ..
# shellcheck disable=SC2086
make -j"$(nproc)" $TARGETS
REMOTE_EOF
  # shellcheck disable=SC2086
  scp $SSH_OPTS "$remote_sh" "$CLT_HOST:/tmp/sephash_client_build.sh"
  remote "$CLT_HOST" "bash /tmp/sephash_client_build.sh '$CLT_SRC' '$CLT_IBDEV' '$targets'"
  log "client build ok on $CLT_HOST"
}

SERVER_PORT="${SERVER_PORT:-10001}"

port_listening() {
  ss -lnt 2>/dev/null | awk -v p=":$SERVER_PORT" '$4 ~ p"$" {found=1} END{exit !found}'
}

# TCP probe: accept loop is up (init logs before listen; do not rely on logs alone)
tcp_probe() {
  local host="${1:-127.0.0.1}"
  timeout 1 bash -c "echo >/dev/tcp/${host}/${SERVER_PORT}" 2>/dev/null
}

stop_server() {
  if [[ -f "$SERVER_PID_FILE" ]]; then
    local pid
    pid="$(cat "$SERVER_PID_FILE" || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      log "stop server pid=$pid"
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 10); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$SERVER_PID_FILE"
  fi
  if [[ -f "$SERVER_KEEPER_PID_FILE" ]]; then
    kill "$(cat "$SERVER_KEEPER_PID_FILE")" 2>/dev/null || true
    kill -9 "$(cat "$SERVER_KEEPER_PID_FILE" 2>/dev/null)" 2>/dev/null || true
    rm -f "$SERVER_KEEPER_PID_FILE"
  fi
  # Fallback: clean by cmdline / port
  pkill -f "/${BIN_FIXED} --server" 2>/dev/null || true
  pkill -f "/${BIN_VAR} --server" 2>/dev/null || true
  fuser -k "${SERVER_PORT}/tcp" 2>/dev/null || true
  rm -f "$SERVER_FIFO" 2>/dev/null || true
  sleep 2
}

start_server() {
  local bin="${1:-$BIN_FIXED}"
  stop_server
  mkdir -p "$(dirname "$SERVER_LOG")"
  : >"$SERVER_LOG"
  rm -f "$SERVER_FIFO"
  mkfifo "$SERVER_FIFO"
  log "start server bin=$bin mem=$MEM_SIZE gid=$GID_IDX dev=$SRV_IBDEV port=$SERVER_PORT"
  (
    cd "$SRV_BUILD"
    # RACE::Server waits on cin.get(); keep stdin open and do not send EOF
    stdbuf -oL -eL "./$bin" --server \
      --gid_idx "$GID_IDX" \
      --max_coro 256 --cq_size 64 \
      --mem_size "$MEM_SIZE" \
      <"$SERVER_FIFO" >>"$SERVER_LOG" 2>&1 &
    echo $! >"$SERVER_PID_FILE"
  )
  # Hold FIFO write end open so the reader does not see EOF
  ( exec 3>"$SERVER_FIFO"; sleep infinity ) &
  echo $! >"$SERVER_KEEPER_PID_FILE"

  local i saw_init=0
  for i in $(seq 1 240); do
    if [[ -f "$SERVER_PID_FILE" ]] && ! kill -0 "$(cat "$SERVER_PID_FILE")" 2>/dev/null; then
      log "server died; tail log:"
      tail -50 "$SERVER_LOG" >&2 || true
      return 1
    fi
    if [[ "$saw_init" -eq 0 ]] && grep -qE 'Server: init|: init$' "$SERVER_LOG" 2>/dev/null; then
      saw_init=1
      log "server init logged (${i}s), waiting for listen :$SERVER_PORT ..."
    fi
    # Port must listen and local TCP connect must succeed (avoid init-before-listen race)
    if port_listening && tcp_probe 127.0.0.1; then
      # Probe RoCE/IB IP again (what the client connects to)
      if tcp_probe "$SRV_IP" || tcp_probe 127.0.0.1; then
        log "server ready (${i}s) listening :$SERVER_PORT"
        sleep 1
        return 0
      fi
    fi
    sleep 1
  done
  log "timeout waiting for server listen; tail:"
  tail -50 "$SERVER_LOG" >&2 || true
  ss -lnt | grep "$SERVER_PORT" || true
  return 1
}

# If client cannot connect, restart server once and retry
run_client_retry() {
  local logfile=$1; shift
  local bin=$1; shift
  local try
  for try in 1 2 3; do
    if run_client "$logfile" "$bin" "$@"; then
      return 0
    fi
    if grep -qE 'connect\(|ECONNREFUSED|Connection refused' "$logfile" 2>/dev/null; then
      log "connect failed (try $try), restart server and retry"
      start_server "$bin" || return 1
      sleep 2
      continue
    fi
    return 1
  done
  return 1
}

# Run one client; log to $1; remaining args go to the binary
# Usage: run_client_logged <logfile> <bin> --server_ip ...
run_client_logged() {
  local logfile=$1; shift
  local bin=$1; shift
  mkdir -p "$(dirname "$logfile")"
  log "client: $bin $*"
  remote "$CLT_HOST" "bash -s" <<EOF
set -euo pipefail
cd '$CLT_BUILD'
rm -f insert_lat*.txt search_lat*.txt out.txt 2>/dev/null || true
stdbuf -oL -eL ./'$bin' \\
  --server_ip '$SRV_IP' \\
  --gid_idx '$GID_IDX' \\
  --max_coro 256 --cq_size 64 \\
  --num_machine 1 --machine_id 0 \\
  "$@"
EOF
}

run_client() {
  local logfile=$1; shift
  local bin=$1; shift
  mkdir -p "$(dirname "$logfile")"
  local args
  args=$(printf '%q ' "$@")
  log "client bin=$bin -> $logfile"
  # shellcheck disable=SC2086
  remote "$CLT_HOST" "cd '$CLT_BUILD' && rm -f insert_lat*.txt search_lat*.txt 2>/dev/null; stdbuf -oL -eL ./$bin --server_ip '$SRV_IP' --gid_idx $GID_IDX --max_coro 256 --cq_size 64 --num_machine 1 --machine_id 0 $args" \
    >"$logfile" 2>&1 || {
      log "client failed; tail:"
      tail -40 "$logfile" >&2 || true
      return 1
    }
}

# Parse metrics from client log → print key=value lines for experiment scripts
parse_client_log() {
  local logfile=$1
  python3 - "$logfile" <<'PY'
import re, sys
text = open(sys.argv[1], errors="ignore").read()
def grab(pat, cast=float, default=""):
    m = re.search(pat, text)
    return cast(m.group(1)) if m else default
load_ms = grab(r"Load duration:([0-9.]+)ms")
load_kops = grab(r"Load IOPS:([0-9.]+)Kops")
run_ms = grab(r"Run duration:([0-9.]+)ms")
run_kops = grab(r"Run IOPS:([0-9.]+)Kops")
entry_util = grab(r"entry_utilization:([0-9.]+)")
space_util = grab(r"space_utilization:([0-9.]+)")
entry_cnt = grab(r"entry_cnt:([0-9]+)", int, 0)
entry_total = grab(r"entry_total:([0-9]+)", int, 0)
print(f"load_ms={load_ms}")
print(f"load_kops={load_kops}")
print(f"run_ms={run_ms}")
print(f"run_kops={run_kops}")
print(f"entry_util={entry_util}")
print(f"space_util={space_util}")
print(f"entry_cnt={entry_cnt}")
print(f"entry_total={entry_total}")
# Kops → Mops; mean latency µs ≈ duration_ms*1000/num_op (caller computes)
if run_kops != "":
    print(f"run_mops={float(run_kops)/1000.0}")
if load_kops != "":
    print(f"load_mops={float(load_kops)/1000.0}")
PY
}

csv_header() {
  local file=$1; shift
  if [[ ! -f "$file" ]]; then
    (IFS=,; echo "$*") >"$file"
  fi
}

csv_row() {
  local file=$1; shift
  (IFS=,; echo "$*") >>"$file"
}

# Set variable value size and rebuild (both ends)
set_varlen_and_rebuild() {
  local vlen=$1
  local klen="${2:-2}"
  log "set varlen key_len=$klen value_len=$vlen"
  sed -i -E \
    -e "s/constexpr uint64_t key_len = [0-9]+;/constexpr uint64_t key_len = ${klen};/" \
    -e "s/constexpr uint64_t value_len = [0-9]+;/constexpr uint64_t value_len = ${vlen};/" \
    "$SRV_SRC/test/ser_cli_var_kv.cc"
  build_local "$BIN_VAR"
  sync_and_build_client "$BIN_VAR"
}

# Preflight: SSH / IPoIB / NIC state
preflight() {
  if [[ "${SKIP_PREFLIGHT:-0}" == "1" ]]; then
    log "SKIP_PREFLIGHT=1"
    return 0
  fi
  log "preflight: SSH $CLT_HOST"
  remote "$CLT_HOST" "hostname; (nproc || true); (ibdev2netdev || true) | head -5" || true
  log "preflight: ping IB $SRV_IP"
  if ! ping -c1 -W2 "$SRV_IP" >/dev/null; then
    log "WARN: cannot ping $SRV_IP (IPoIB?)"
  fi
  if ! remote "$CLT_HOST" "ping -c1 -W2 '$SRV_IP' >/dev/null 2>&1"; then
    log "WARN: client cannot ping $SRV_IP (tool/disk may be broken)"
  fi
  local st
  st="$(ibdev2netdev 2>/dev/null | grep "$SRV_IBDEV" || true)"
  log "local IB: $st"
  if [[ "$st" != *"(Up)"* ]]; then
    log "ERROR: $SRV_IBDEV not Up on memserver16"
    return 1
  fi
  st="$(remote "$CLT_HOST" "ibdev2netdev 2>/dev/null | grep '$CLT_IBDEV' || true")"
  log "client IB: $st"
  if [[ "$st" != *"(Up)"* ]]; then
    # Even if client userspace tools fail (RO disk), ser_cli may still run
    if remote "$CLT_HOST" "test -x '$CLT_BUILD/$BIN_FIXED'"; then
      log "WARN: cannot confirm $CLT_IBDEV Up, but client binary exists — continue"
    else
      log "ERROR: $CLT_IBDEV not Up on $CLT_HOST and no client binary"
      return 1
    fi
  fi
  log "preflight ok"
}
