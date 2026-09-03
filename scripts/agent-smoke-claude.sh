#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage: scripts/agent-smoke-claude.sh [--allow-create-disposable-session]

Read-only by default: prints the Claude Code CLI version and session metadata.
The optional flag runs one harmless, non-persistent stream-json session with
tools disabled. It never uses a permission-bypass option.

REMOTEAI_CLAUDE_CLI may be set to an alternate claude executable for testing.
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

claude_cli=${REMOTEAI_CLAUDE_CLI:-claude}
if ! claude_path=$(command -v "$claude_cli" 2>/dev/null) || [ ! -x "$claude_path" ]; then
  printf 'error: Claude Code CLI not found (%s). Install Claude Code or set REMOTEAI_CLAUDE_CLI.\n' "$claude_cli" >&2
  exit 127
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'error: python3 is required to safely inspect JSON metadata; install Python 3.\n' >&2
  exit 127
fi

set +e
version_output=$("$claude_path" --version 2>/dev/null)
version_status=$?
set -e
if [ "$version_status" -ne 0 ] || [ -z "$version_output" ]; then
  printf 'error: Claude Code CLI could not report its version. Check installation and login with `claude --version`.\n' >&2
  exit 1
fi
version_line=$(printf '%s\n' "$version_output" | sed -n '1p')
printf 'Claude Code CLI: %s\n' "$version_line"

if [ "$allow_create" -eq 1 ]; then
  stream_output=''
  set +e
  stream_output=$("$claude_path" \
    --print \
    --input-format stream-json \
    --output-format stream-json \
    --include-partial-messages \
    --permission-mode manual \
    --tools "" \
    --no-session-persistence \
    2>/dev/null <<'JSON'
{"type":"user","message":{"role":"user","content":"RemoteAI disposable smoke test. Reply with one short confirmation and do not use tools."}}
JSON
  )
  stream_status=$?
  set -e
  if [ "$stream_status" -ne 0 ]; then
    printf 'error: Claude could not complete the disposable session. Check `claude --print` and local CLI health.\n' >&2
    exit 1
  fi
  if ! printf '%s\n' "$stream_output" | python3 -c '
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
    if message.get("type") == "system" and message.get("subtype") == "init":
        session_id = message.get("session_id")
        if isinstance(session_id, str) and session_id:
            print("Created one disposable Claude session: " + clean(session_id))
            print("Tools were disabled and session persistence was disabled.")
            sys.exit(0)
print("Disposable Claude session completed (session id unavailable).")
sys.exit(0)
'; then
    printf 'hint: verify that this Claude version supports stream-json input/output.\n' >&2
    exit 1
  fi
  exit 0
fi

agents_output=''
set +e
agents_output=$("$claude_path" agents --json --all 2>/dev/null)
agents_status=$?
set -e
if [ "$agents_status" -ne 0 ]; then
  printf 'note: `claude agents --json` is unavailable; showing local session filenames only.\n' >&2
else
  if ! printf '%s\n' "$agents_output" | python3 -c '
import json
import re
import sys

def clean(value):
    text = str(value or "").replace("\r", " ").replace("\n", " ")
    text = re.sub(r"(?i)(token|secret|password|api[_-]?key|cookie|authorization)(\s*[:=]\s*)\S+", r"\1\2[redacted]", text)
    return text[:200]

try:
    value = json.load(sys.stdin)
except (TypeError, ValueError):
    print("note: Claude returned no parseable agent metadata.", file=sys.stderr)
    sys.exit(0)
rows = value if isinstance(value, list) else value.get("sessions", []) if isinstance(value, dict) else []
print("Claude active/completed session metadata (read-only):")
if not rows:
    print("  (none reported)")
for row in rows:
    if not isinstance(row, dict):
        continue
    identifier = row.get("session_id") or row.get("sessionId") or row.get("id") or "(unknown)"
    cwd = row.get("cwd") or row.get("projectPath") or row.get("project_path") or "(unknown)"
    status = row.get("status") or row.get("state") or "unknown"
    print("  - id=%s cwd=%s status=%s" % (clean(identifier), clean(cwd), clean(status)))
'; then
    printf 'note: unable to parse Claude agent metadata; continuing with filenames.\n' >&2
  fi
fi

projects_root=${HOME:-}/.claude/projects
printf 'Claude persisted session metadata (filenames only; transcript contents are never read):\n'
if [ -d "$projects_root" ]; then
  find "$projects_root" -type f -name '*.jsonl' -print 2>/dev/null |
    while IFS= read -r session_path; do
      session_file=${session_path##*/}
      session_id=${session_file%.jsonl}
      case "$session_id" in
        ????????-????-????-????-????????????)
          project_dir=${session_path%/*}
          project_name=${project_dir##*/}
          safe_project=$(printf '%s' "$project_name" | tr -cd 'A-Za-z0-9._-')
          modified='unknown'
          if modified=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$session_path" 2>/dev/null); then
            :
          elif modified=$(stat -c '%Y' "$session_path" 2>/dev/null); then
            :
          fi
          printf '  - id=%s project=%s modified=%s\n' "$session_id" "${safe_project:-unknown}" "$modified"
          ;;
      esac
    done
else
  printf '  (Claude project directory not found; no files were created.)\n'
fi
