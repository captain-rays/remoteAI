#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/agent-smoke-codex.sh [--allow-create-disposable-session]

Read-only by default: prints the Codex CLI version and thread metadata.
The optional flag creates exactly one disposable thread in a temporary
directory. It never sends a turn and never enables permission bypasses.

REMOTEAI_CODEX_CLI may be set to an alternate codex executable for testing.
EOF
}

allow_create=0
for arg in "$@"; do
  case "$arg" in
    --allow-create-disposable-session) allow_create=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'error: unknown argument: %s\n' "$arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

codex_cli=${REMOTEAI_CODEX_CLI:-codex}
if ! codex_path=$(command -v "$codex_cli" 2>/dev/null) || [ ! -x "$codex_path" ]; then
  printf 'error: Codex CLI not found (%s). Install Codex or set REMOTEAI_CODEX_CLI.\n' "$codex_cli" >&2
  exit 127
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'error: python3 is required to safely inspect JSON metadata; install Python 3.\n' >&2
  exit 127
fi

set +e
version_output=$("$codex_path" --version 2>/dev/null)
version_status=$?
set -e
if [ "$version_status" -ne 0 ] || [ -z "$version_output" ]; then
  printf 'error: Codex CLI could not report its version. Check installation and login with `codex --version`.\n' >&2
  exit 1
fi
version_line=$(printf '%s\n' "$version_output" | sed -n '1p')
printf 'Codex CLI: %s\n' "$version_line"

disposable_dir=''
cleanup() {
  if [ -n "$disposable_dir" ] && [ -d "$disposable_dir" ]; then
    rm -rf "$disposable_dir"
  fi
}
trap cleanup EXIT INT TERM

if [ "$allow_create" -eq 1 ]; then
  disposable_dir=$(mktemp -d "${TMPDIR:-/tmp}/remoteai-codex-smoke.XXXXXX")
  rpc_output=''
  set +e
  rpc_output=$("$codex_path" app-server --stdio 2>/dev/null <<EOF
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"remote-ai-smoke","version":"1"}}}
{"method":"initialized","params":{}}
{"id":2,"method":"thread/start","params":{"cwd":"$disposable_dir","approvalPolicy":"on-request","approvalsReviewer":"user"}}
EOF
  )
  rpc_status=$?
  set -e
  if [ "$rpc_status" -ne 0 ]; then
    printf 'error: Codex app-server could not create the disposable thread. Check `codex app-server --stdio`.\n' >&2
    exit 1
  fi
  if ! printf '%s\n' "$rpc_output" | python3 -c '
import json
import re
import sys

def clean(value):
    text = str(value or "").replace("\r", " ").replace("\n", " ")
    text = re.sub(r"(?i)(token|secret|password|api[_-]?key|cookie|authorization)(\s*[:=]\s*)\S+", r"\1\2[redacted]", text)
    return text[:200]

for raw in sys.stdin:
    try:
        message = json.loads(raw)
    except (TypeError, ValueError):
        continue
    if str(message.get("id")) != "2":
        continue
    if "error" in message:
        print("error: Codex rejected the disposable thread request", file=sys.stderr)
        sys.exit(1)
    result = message.get("result") or {}
    thread = result.get("thread") if isinstance(result, dict) else None
    if not isinstance(thread, dict):
        thread = result if isinstance(result, dict) else {}
    thread_id = thread.get("id")
    if not isinstance(thread_id, str) or not thread_id:
        print("error: Codex did not return a disposable thread id", file=sys.stderr)
        sys.exit(1)
    print("Created one disposable Codex session: " + clean(thread_id))
    print("No turn was sent; the temporary working directory will be removed.")
    sys.exit(0)

print("error: Codex returned no thread/start response", file=sys.stderr)
sys.exit(1)
'; then
    printf 'hint: verify that this Codex version supports app-server thread/start.\n' >&2
    exit 1
  fi
  exit 0
fi

rpc_output=''
set +e
rpc_output=$("$codex_path" app-server --stdio 2>/dev/null <<'EOF'
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"remote-ai-smoke","version":"1"}}}
{"method":"initialized","params":{}}
{"id":2,"method":"thread/list","params":{"sortDirection":"desc","limit":100}}
EOF
)
rpc_status=$?
set -e
if [ "$rpc_status" -ne 0 ]; then
  printf 'error: Codex app-server could not list threads. Check `codex app-server --stdio` and local CLI health.\n' >&2
  exit 1
fi

if ! printf '%s\n' "$rpc_output" | python3 -c '
import json
import os
import re
import sys

home = os.path.realpath(sys.argv[1])

def clean(value):
    text = str(value or "").replace("\r", " ").replace("\n", " ")
    text = re.sub(r"(?i)(token|secret|password|api[_-]?key|cookie|authorization)(\s*[:=]\s*)\S+", r"\1\2[redacted]", text)
    return text[:200]

seen_response = False
for raw in sys.stdin:
    try:
        message = json.loads(raw)
    except (TypeError, ValueError):
        continue
    if str(message.get("id")) != "2":
        continue
    seen_response = True
    if "error" in message:
        print("error: Codex rejected the thread listing request", file=sys.stderr)
        sys.exit(1)
    result = message.get("result") or message
    rows = result.get("data") if isinstance(result, dict) else None
    if not isinstance(rows, list):
        print("error: Codex thread/list response did not contain metadata", file=sys.stderr)
        sys.exit(1)
    print("Codex sessions (read-only metadata):")
    if not rows:
        print("  (none reported)")
    for row in rows:
        if not isinstance(row, dict):
            continue
        cwd = row.get("cwd") if isinstance(row.get("cwd"), str) else ""
        kind = "daily" if not cwd or os.path.realpath(cwd) == home else "project"
        status = row.get("status")
        if isinstance(status, dict):
            status = status.get("type")
        print("  - id=%s kind=%s title=%s cwd=%s updated=%s status=%s" % (
            clean(row.get("id")),
            kind,
            clean(row.get("name") or row.get("title") or "(untitled)"),
            clean(cwd or "(none)"),
            clean(row.get("updatedAt") or row.get("updated_at") or "(unknown)"),
            clean(status or "unknown"),
        ))
    sys.exit(0)

if not seen_response:
    print("error: Codex returned no thread/list response", file=sys.stderr)
    sys.exit(1)
' "${HOME:-}"; then
  printf 'hint: upgrade Codex if app-server thread/list is unavailable.\n' >&2
  exit 1
fi
