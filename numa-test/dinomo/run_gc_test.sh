#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export NUM_KEYS=${NUM_KEYS:-32}
export GC_ROUNDS=${GC_ROUNDS:-512}
export POOL_MB=${POOL_MB:-16}
export LOG_BLOCK_LIMIT=${LOG_BLOCK_LIMIT:-64}
exec "$SCRIPT_DIR/run_network_test.sh" "$@"
