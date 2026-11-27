#!/usr/bin/env bash
# Runs all BudgetKit tests on Linux in Swift's official Docker image, including the sync tests
# against the local test backend (start it first with scripts/start-test-backend.sh).
#   scripts/test-linux.sh /path/to/budget-app [extra swift test args]
set -euo pipefail
WEB="$(cd "${1:-$(dirname "$0")/../..}" && pwd)"; shift || true
cd "$(dirname "$0")/.."
WORK="${WORK:-/tmp/budget-test-backend}"
docker run --rm --network host -v "$PWD":/w -w /w \
  -v "$WEB":/web:ro -v "$WORK/node_modules":/node_modules:ro -v "$(command -v node)":/usr/bin/node:ro \
  -e SUPABASE_TEST_URL=http://localhost:54321 -e WEB_APP_DIR=/web -e NODE_MODULES_DIR=/node_modules -e WEBPHONE_SCRIPT=/w/scripts/webphone.mjs \
  swift:6.0-noble swift test "$@"
