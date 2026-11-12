#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export CONCURRENT_MERGE=1
export MERGE_WRITES=${MERGE_WRITES:-16}
export MERGE_MS=${MERGE_MS:-0}
export REQUIRE_DEFERRED=1
export REQUIRE_OVERLAP=1
export MERGE_LOCK_DELAY_MS=${MERGE_LOCK_DELAY_MS:-5}
export LOG_BLOCK_LIMIT=${LOG_BLOCK_LIMIT:-96}
exec "$SCRIPT_DIR/run_gc_test.sh" "$@"
