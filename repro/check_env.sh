#!/usr/bin/env bash
# Check that memserver16 + bfhost_72 can run RACE repro
set -euo pipefail
REPRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$REPRO_DIR/lib.sh"

log "==== SepHash/RACE env check ===="
log "host=$(hostname) SRV_IP=$SRV_IP CLT_HOST=$CLT_HOST"
log "SRV_IBDEV=$SRV_IBDEV CLT_IBDEV=$CLT_IBDEV GID_IDX=$GID_IDX"
log "CLT_SRC=$CLT_SRC MEM_SIZE=$MEM_SIZE"

preflight

log "IB GIDs (local $SRV_IBDEV):"
show_gids 2>/dev/null | grep -E "^$SRV_IBDEV" || show_gids 2>/dev/null | head -20

log "IB GIDs (client $CLT_IBDEV):"
remote "$CLT_HOST" "show_gids 2>/dev/null | grep -E '^$CLT_IBDEV' || show_gids 2>/dev/null | head -20"

log "compiler local=$(pick_cxx)"
remote "$CLT_HOST" 'if [[ -x /usr/bin/g++-13 ]]; then echo g++-13; elif [[ -x /usr/bin/g++-11 ]]; then echo g++-11; else g++ --version | head -1; fi'

log "ping IB both ways ok (see preflight)"
log "==== check_env DONE ===="
