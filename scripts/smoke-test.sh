#!/usr/bin/env bash
# Local smoke test: build, start, and wait until the panel answers.
#
# The panel is loopback-only inside the container, so this asks the published
# port (which lands on the socat proxy) rather than the container directly.
set -euo pipefail

PORT="${SUPERAGENT_PORT:-3082}"
API="http://127.0.0.1:${PORT}/orchestrator/api/state"

echo "== building and starting =="
docker compose up -d --build

echo "== waiting for the management API on :$PORT =="
for _ in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H 'x-orchestrator-request: 1' "$API" || true)
  if [ "$code" = "200" ]; then
    echo "API answered 200"
    break
  fi
  sleep 3
done

if [ "${code:-}" != "200" ]; then
  echo "API did not come up; last container logs:"
  docker compose logs --tail 40 superagent
  exit 1
fi

echo "== setup state =="
curl -s -H 'x-orchestrator-request: 1' "$API" | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("setup"), ensure_ascii=False, indent=2))'

echo "== service status (0 healthy, 2 part error, 3 setup waits: all expected) =="
docker compose exec -T superagent scripts/dsh-superagent status || true

echo
echo "Open the panel:"
docker compose logs superagent | grep -o 'http://localhost:[0-9]*/?token=[A-Za-z0-9_-]*' | tail -1
