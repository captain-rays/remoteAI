#!/bin/sh
set -eu

case ":${PATH}:" in
  *:/opt/homebrew/opt/rustup/bin:*) ;;
  *) PATH="/opt/homebrew/opt/rustup/bin:$PATH"; export PATH ;;
esac

# Deterministic localhost-only smoke harness. It exercises health, pairing,
# and provider-scoped catalog routes without external network or sync.
bind=${REMOTEAI_MOCK_BIND:-127.0.0.1:8788}
base="http://${bind}"
log=$(mktemp /tmp/remoteai-agent-e2e.XXXXXX)
cleanup() {
  if [ -n "${agent_pid:-}" ]; then kill "$agent_pid" 2>/dev/null || true; fi
  rm -f "$log"
}
trap cleanup EXIT INT TERM

cargo run -q -p remote-ai-agent --bin mock-agent >"$log" 2>&1 &
agent_pid=$!
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60; do
  if curl -fsS "$base/v1/health" >/dev/null 2>&1; then break; fi
  sleep 1
done
if ! curl -fsS "$base/v1/health" >/dev/null 2>&1; then
  printf '%s\n' 'mock Agent failed to become ready:' >&2
  sed -n '1,120p' "$log" >&2
  exit 1
fi
curl -fsS -X POST "$base/v1/pair" \
  -H 'content-type: application/json' \
  -d '{"pairingSecret":"mock-secret","deviceId":"simulator","deviceLabel":"Simulator","devicePublicKey":[4,2]}' >/dev/null
curl -fsS "$base/v1/conversations/daily?provider=codex" \
  -H 'x-remoteai-device: simulator' >/dev/null
transfer_count=$(curl -fsS "$base/v1/mock/transfer-count")
case "$transfer_count" in
  *'"transferRequests":0'*) ;;
  *)
    printf '%s\n' 'mock Agent reported unexpected transfer requests while idle:' >&2
    printf '%s\n' "$transfer_count" >&2
    exit 1
    ;;
esac
printf '%s\n' 'mock Agent e2e simulator passed (localhost-only; no automatic sync)'
