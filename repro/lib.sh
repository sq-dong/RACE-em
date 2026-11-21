#!/usr/bin/env bash
# shellcheck shell=bash
# 公共：同步、编译、启停 server、跑 client、解析日志
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

SERVER_PID_FILE="${RESULTS_DIR}/.server.pid"
SERVER_KEEPER_PID_FILE="${RESULTS_DIR}/.server.keeper.pid"
SERVER_FIFO="${RESULTS_DIR}/.server.stdin"
SERVER_LOG="${RESULTS_DIR}/logs/server.log"

ensure_race_sources() {
  # 确保本地已切到 RACE（幂等）
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

build_local() {
  local targets="${1:-$BIN_FIXED $BIN_VAR}"
  ensure_race_sources
  mkdir -p "$SRV_BUILD"
  (
    cd "$SRV_BUILD"
    if [[ ! -f Makefile ]]; then
      cmake "$SRV_SRC"
    fi
    # shellcheck disable=SC2086
    make -j"$(nproc)" $targets
  )
  log "local build ok: $targets"
}

sync_and_build_client() {
  local targets="${1:-$BIN_FIXED $BIN_VAR}"
  log "rsync -> $CLT_HOST:$CLT_SRC"
  rsync -az --delete \
    --exclude build --exclude .git --exclude 'repro/results' \
    "$SRV_SRC/" "$CLT_HOST:$CLT_SRC/"

  remote "$CLT_HOST" "bash -s" <<EOF
set -euo pipefail
cd '$CLT_SRC'
# client 网卡
sed -i 's/rdma_dev dev("mlx5_0"/rdma_dev dev("mlx5_3"/' test/ser_cli.cc test/ser_cli_var_kv.cc || true
# g++-13 on Ubuntu 24.04
if [[ -x /usr/bin/g++-13 ]]; then
  sed -i 's|/usr/bin/g++-11|/usr/bin/g++-13|' CMakeLists.txt || true
fi
# RACE
for f in test/ser_cli.cc test/ser_cli_var_kv.cc; do
  sed -i \\
    -e 's/using ClientType = SEPHASH::Client;/using ClientType = RACE::Client;/' \\
    -e 's/using ServerType = SEPHASH::Server;/using ServerType = RACE::Server;/' \\
    -e 's/using Slice = SEPHASH::Slice;/using Slice = RACE::Slice;/' \\
    "\$f"
done
mkdir -p build && cd build
if [[ ! -f Makefile ]]; then
  if [[ -x /usr/bin/g++-13 ]]; then
    cmake -DCMAKE_CXX_COMPILER=g++-13 ..
  else
    cmake ..
  fi
fi
make -j"\$(nproc)" $targets
EOF
  log "client build ok on $CLT_HOST"
}

SERVER_PORT="${SERVER_PORT:-10001}"

port_listening() {
  ss -lnt 2>/dev/null | awk -v p=":$SERVER_PORT" '$4 ~ p"$" {found=1} END{exit !found}'
}

# TCP 探测：确认 accept 循环已起来（init 日志在 listen 之前，不能单靠它）
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
  # 兜底：按命令行 / 端口清理
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
  log "start server bin=$bin mem=$MEM_SIZE gid=$GID_IDX port=$SERVER_PORT"
  (
    cd "$SRV_BUILD"
    # RACE::Server 用 cin.get() 等退出；必须保持 stdin 打开且不送 EOF
    stdbuf -oL -eL "./$bin" --server \
      --gid_idx "$GID_IDX" \
      --max_coro 256 --cq_size 64 \
      --mem_size "$MEM_SIZE" \
      <"$SERVER_FIFO" >>"$SERVER_LOG" 2>&1 &
    echo $! >"$SERVER_PID_FILE"
  )
  # 打开 FIFO 写端并挂起，阻止读端收到 EOF
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
    # 必须端口在听，并且本机 TCP 能连上（避免 init 早于 listen 的竞态）
    if port_listening && tcp_probe 127.0.0.1; then
      # 再探一次 RoCE IP（client 实际连这个）
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

# client 连不上时自动重启 server 再试一次
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

# 跑一次 client，日志写入 $1；其余参数传给二进制
# 用法: run_client_logged <logfile> <bin> --server_ip ... 
run_client_logged() {
  local logfile=$1; shift
  local bin=$1; shift
  mkdir -p "$(dirname "$logfile")"
  log "client: $bin $*"
  # 在 client 机 cwd=build，便于 lat 文件落盘
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
  # 上面 "$@" 在 heredoc 里不会展开本地参数——需换写法
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

# 从 client 日志解析指标 → 打印 key=value 行（供实验脚本采集）
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
# Kops → Mops；平均时延 µs ≈ duration_ms*1000/num_op（由调用方再算）
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

# 设置变长 value 大小并重编（两端）
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
