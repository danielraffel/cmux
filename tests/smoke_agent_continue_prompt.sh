#!/bin/bash
# Smoke-tests the `cmux agent-continue-prompt` contract that Subrouter's
# resumer depends on, against a built CLI, with no app and no socket.
#
#   tests/smoke_agent_continue_prompt.sh <path-to-built-cmux-cli>
#
# Subrouter runs `--dry-run --json` and reads exactly the keys `prompt` and
# `claim_token`, then runs `--commit <token>` after a successful submit. It
# treats exit 3 (idle), 4 (already continued) and 5 (unreadable transcript)
# as "type nothing", and any other result as an older cmux, which makes it
# type the legacy "continue". A drift here is therefore silent, so this
# script checks every part of that contract against the real binary.
#
# Fixture rollouts are written under a scratch HOME, which is also passed as
# CFFIXED_USER_HOME so NSHomeDirectory() resolves there. The user's real
# ~/.codex and continue ledger are never read or written.
set -uo pipefail

CLI=${1:?usage: tests/smoke_agent_continue_prompt.sh <path-to-built-cmux-cli>}
[ -x "$CLI" ] || { echo "not executable: $CLI" >&2; exit 2; }
PYTHON=${PYTHON:-/usr/bin/python3}

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cmux-continue-smoke.XXXXXX") || exit 2
trap 'rm -rf "$SCRATCH"' EXIT
LEDGER="$SCRATCH/Library/Application Support/cmux/agent-auto-continue"

BUSY=01a10852-5eed-7993-bee8-c40693a36dc3
IDLE=01a10852-1111-7000-8000-000000000001
UNKNOWN=01a10852-2222-7000-8000-000000000002

"$PYTHON" - "$SCRATCH" "$BUSY" "$IDLE" <<'PY' || { echo "fixture setup failed" >&2; exit 2; }
import json, os, sys
home, busy, idle = sys.argv[1:4]
day = os.path.join(home, ".codex", "sessions", "2026", "10", "13")
os.makedirs(day)
def write(session, entries):
    with open(os.path.join(day, f"rollout-2026-10-13T10-00-00-{session}.jsonl"), "w") as f:
        for entry in entries:
            f.write(json.dumps(entry) + "\n")
write(busy, [
    {"type": "session_meta", "timestamp": "2026-10-13T09:59:59.000Z", "payload": {"id": busy, "model_provider": "subrouter"}},
    {"type": "event_msg", "timestamp": "2026-10-13T10:00:00.000Z", "payload": {"type": "task_started"}},
    {"type": "response_item", "timestamp": "2026-10-13T10:00:01.000Z", "payload": {"type": "custom_tool_call", "call_id": "c1", "name": "exec"}},
])
write(idle, [
    {"type": "session_meta", "timestamp": "2026-10-13T10:59:59.000Z", "payload": {"id": idle, "model_provider": "subrouter"}},
    {"type": "event_msg", "timestamp": "2026-10-13T11:00:00.000Z", "payload": {"type": "task_started"}},
    {"type": "event_msg", "timestamp": "2026-10-13T11:00:05.000Z", "payload": {"type": "task_complete", "error": None}},
])
PY

FAILURES=0
OUT="$SCRATCH/out"
ERR="$SCRATCH/err"

# Runs the verb exactly as Subrouter does, in a clean environment whose
# socket path names nothing.
run() {
  env -i PATH=/usr/bin:/bin HOME="$SCRATCH" CFFIXED_USER_HOME="$SCRATCH" \
    CMUX_SOCKET_PATH="$SCRATCH/no-app.sock" \
    "$CLI" agent-continue-prompt "$@" >"$OUT" 2>"$ERR"
  STATUS=$?
  echo "\$ cmux agent-continue-prompt $*"
  echo "  exit=$STATUS stdout_bytes=$(wc -c <"$OUT" | tr -d ' ')"
  [ -s "$ERR" ] && echo "  stderr: $(head -c 300 "$ERR")"
}

check() {
  if [ "$1" = "$2" ]; then
    echo "  ok: $3"
  else
    echo "  FAIL: $3 (expected $2, got $1)"
    FAILURES=$((FAILURES + 1))
  fi
}

claims() { find "$LEDGER" -name '*.claim' 2>/dev/null | wc -l | tr -d ' '; }

echo "cli: $CLI"
echo

run --kind codex --session "$BUSY" --reason quota --dry-run --json
check "$STATUS" 0 "interrupted session: dry run exits 0"
KEYS=$("$PYTHON" -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])).keys())))' "$OUT" 2>/dev/null)
check "$KEYS" "claim_token,prompt" "dry run prints JSON with exactly the keys Subrouter parses"
PROMPT=$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["prompt"])' "$OUT" 2>/dev/null)
TOKEN=$("$PYTHON" -c 'import json,sys; print(json.load(open(sys.argv[1]))["claim_token"])' "$OUT" 2>/dev/null)
case "$PROMPT" in
  *"(exec) has no recorded result"*"Never redo a step"*) check yes yes "prompt names the open tool call and the verify-first rules" ;;
  *) check no yes "prompt names the open tool call and the verify-first rules" ;;
esac
[ -n "$TOKEN" ] && check yes yes "claim token is present" || check no yes "claim token is present"
check "$(claims)" 0 "dry run claims nothing"
echo

run --kind codex --session "$IDLE" --reason quota --dry-run --json
check "$STATUS" 3 "idle session: exit 3"
check "$(wc -c <"$OUT" | tr -d ' ')" 0 "idle session prints nothing"
echo

run --kind codex --session "$UNKNOWN" --reason quota --dry-run --json
check "$STATUS" 5 "unknown transcript: exit 5"
check "$(wc -c <"$OUT" | tr -d ' ')" 0 "unknown transcript prints nothing"
echo

run --kind codex --session "$BUSY" --reason quota --commit "$TOKEN"
check "$STATUS" 0 "first commit claims: exit 0"
check "$(wc -c <"$OUT" | tr -d ' ')" 0 "commit prints nothing"
check "$(claims)" 1 "commit writes one claim"
CLAIM_STATE=$("$PYTHON" -c 'import json,sys,glob; c=json.load(open(glob.glob(sys.argv[1]+"/*.claim")[0])); print(c["state"], c["last_entry_was_open_tool_call"], c["pending_tool"], c["interrupted_at"])' "$LEDGER" 2>/dev/null)
check "$CLAIM_STATE" "midToolCall True exec 2026-10-13T10:00:01Z" "claim records the interruption the prompt was built for"
echo

run --kind codex --session "$BUSY" --reason quota --commit "$TOKEN"
check "$STATUS" 4 "repeat commit: exit 4"
echo

run --kind codex --session "$BUSY" --reason quota --dry-run --json
check "$STATUS" 4 "dry run after the claim: exit 4"
check "$(claims)" 1 "still exactly one claim"
echo

if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: agent-continue-prompt contract holds"
else
  echo "FAIL: $FAILURES check(s) failed"
fi
exit $((FAILURES > 0))
