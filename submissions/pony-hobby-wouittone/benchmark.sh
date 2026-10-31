#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
OUT="$PWD/bin/performance"
mkdir -p "$OUT"
export DATABASE_URL="postgres://conduit:conduit@127.0.0.1:${PGPORT:-5432}/conduit_seed"
export JWT_SECRET=local-performance-only HOST=127.0.0.1 PORT=3110
(cd "$ROOT/bench" && go build -o "$OUT/loadgen" ./cmd/loadgen)
{
  uname -a
  lscpu
  free -h
  echo "Full seed; direct HTTP; server, PostgreSQL, and generator share this machine."
} > "$OUT/environment.txt"
bash start.sh > "$OUT/server.log" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true' EXIT
for _ in $(seq 60); do curl -sf -o /dev/null http://127.0.0.1:3110/api/tags && break; sleep 1; done
curl -sf -o /dev/null http://127.0.0.1:3110/api/tags
BEST=0
for USERS in 500 2000 5000 10000; do
  "$OUT/loadgen" run -target http://127.0.0.1:3110 -users "$USERS" \
    -ramp 30s -measure 60s -tail 5s -secret "$JWT_SECRET" \
    -run-id "ci-${GITHUB_RUN_ID:-local}-$USERS" -out "$OUT/probe-$USERS.json"
  RC=0
  "$OUT/loadgen" merge -o "$OUT/probe-$USERS-merged.json" "$OUT/probe-$USERS.json" \
    > "$OUT/probe-$USERS.txt" 2>&1 || RC=$?
  cat "$OUT/probe-$USERS.txt"
  if [ "$RC" -ne 0 ] && [ "$RC" -ne 3 ]; then exit "$RC"; fi
  if [ "$RC" -eq 3 ]; then break; fi
  if jq -e '.verdict.lg_limited == true' "$OUT/probe-$USERS-merged.json" >/dev/null; then break; fi
  BEST=$USERS
done
if [ "$BEST" -gt 0 ]; then
  "$OUT/loadgen" run -target http://127.0.0.1:3110 -users "$BEST" \
    -ramp 60s -measure 300s -tail 5s -secret "$JWT_SECRET" \
    -run-id "ci-${GITHUB_RUN_ID:-local}-hold" -out "$OUT/hold.json"
  RC=0
  "$OUT/loadgen" merge -o "$OUT/hold-merged.json" "$OUT/hold.json" \
    > "$OUT/hold.txt" 2>&1 || RC=$?
  cat "$OUT/hold.txt"
  if [ "$RC" -ne 0 ] && [ "$RC" -ne 3 ]; then exit "$RC"; fi
fi
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo '## Pony/Hobby performance screen'
    echo 'Full seed, direct HTTP, shared runner and co-located load generator. Not an official score.'
    for FILE in "$OUT"/probe-*.txt "$OUT"/hold.txt; do
      [ -f "$FILE" ] || continue
      echo '```text'
      cat "$FILE"
      echo '```'
    done
  } >> "$GITHUB_STEP_SUMMARY"
fi
