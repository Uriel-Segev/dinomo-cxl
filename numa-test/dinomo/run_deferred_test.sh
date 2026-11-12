#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Timer disabled so the initial eight-write probe deterministically observes
# both active staging and copied logs before the first threshold merge.
export MERGE_WRITES=${MERGE_WRITES:-16}
export MERGE_MS=${MERGE_MS:-0}
export REQUIRE_DEFERRED=1
exec "$SCRIPT_DIR/run_gc_test.sh" "$@"
