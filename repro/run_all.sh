#!/usr/bin/env bash
# Run RACE (SepHash tree) reproducible experiments and plot figures.
#
# Usage:
#   SCALE=smoke   ./run_all.sh              # quick check (minutes)
#   SCALE=medium  ./run_all.sh              # default, hours
#   SCALE=paper   ./run_all.sh              # paper-scale (may take >10h)
#   EXPTS="race_tput race_ycsb" ./run_all.sh
#   ./run_all.sh --plot-only
#
set -euo pipefail
REPRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$REPRO_DIR/lib.sh"
scale_params

PLOT_ONLY=0
if [[ "${1:-}" == "--plot-only" ]]; then
  PLOT_ONLY=1
fi

declare -A EXPT_SCRIPT=(
  [race_tput]="$REPRO_DIR/experiments/race_tput.sh"
  [race_hybrid]="$REPRO_DIR/experiments/race_hybrid.sh"
  [race_latency]="$REPRO_DIR/experiments/race_latency.sh"
  [race_ycsb]="$REPRO_DIR/experiments/race_ycsb.sh"
  [race_varlen]="$REPRO_DIR/experiments/race_varlen.sh"
  [sephash_insert]="$REPRO_DIR/experiments/sephash_insert.sh"
  [sephash_hybrid]="$REPRO_DIR/experiments/sephash_hybrid.sh"
)

if [[ "$PLOT_ONLY" -eq 0 ]]; then
  log "==== SepHash/RACE repro START scale=$SCALE expts=[$EXPTS] ===="
  log "SRV_IP=$SRV_IP CLT_HOST=$CLT_HOST MEM_SIZE=$MEM_SIZE SRV_IBDEV=$SRV_IBDEV CLT_IBDEV=$CLT_IBDEV"
  chmod +x "$REPRO_DIR"/experiments/*.sh "$REPRO_DIR"/run_all.sh "$REPRO_DIR"/check_env.sh || true
  preflight || {
    log "preflight failed; set SKIP_PREFLIGHT=1 to override"
    exit 1
  }

  failed=()
  for ex in $EXPTS; do
    script="${EXPT_SCRIPT[$ex]:-}"
    if [[ -z "$script" || ! -f "$script" ]]; then
      log "unknown experiment: $ex"
      failed+=("$ex")
      continue
    fi
    log ">>>> begin $ex"
    if ! bash "$script"; then
      log "!!!! $ex FAILED (continue)"
      failed+=("$ex")
    else
      log "<<<< done $ex"
    fi
    stop_server || true
  done

  if ((${#failed[@]})); then
    log "failed experiments: ${failed[*]}"
  fi
fi

log "plotting..."
python3 "$REPRO_DIR/plot_all.py" --results "$RESULTS_DIR"
log "figures -> $FIGURES_DIR"
log "==== DONE ===="
