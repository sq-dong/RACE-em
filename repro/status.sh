#!/usr/bin/env bash
# 查看 SCALE=paper 后台进度 + RoCE 面
set -euo pipefail
REPRO="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=env.sh
source "$REPRO/env.sh"
LOG=$(ls -t "$REPRO"/results/logs/run_all_paper_*.log 2>/dev/null | head -1 || true)
echo "=== RoCE ==="
if ping -c 1 -W 1 10.0.0.21 >/dev/null 2>&1; then
  echo "10.0.0.20 -> 10.0.0.21 OK"
else
  echo "10.0.0.20 -> 10.0.0.21 FAIL (see $REPRO/NETWORK_BLOCKER.md)"
fi
echo
echo "=== processes ==="
ps aux | grep -E 'run_all\.sh|ser_cli' | grep -v grep || echo '(none)'
echo
echo "=== main log: ${LOG:-none} ==="
[[ -n "${LOG:-}" ]] && tail -30 "$LOG"
echo
echo "=== csv rows ==="
for f in "$REPRO"/results/*.csv; do
  [[ -f "$f" ]] || continue
  printf '%5d  %s\n' "$(wc -l <"$f")" "$(basename "$f")"
done
echo
CLT=$(ls -t "$REPRO"/results/logs/race_*.log "$REPRO"/results/logs/sephash_*.log 2>/dev/null | head -1 || true)
if [[ -n "${CLT:-}" ]]; then
  echo "=== latest client log: $CLT ==="
  tail -15 "$CLT"
fi
