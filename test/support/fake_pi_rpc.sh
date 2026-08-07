#!/usr/bin/env bash
# Fake pi --mode rpc peer for unit tests (no network).
# Modes via FAKE_PI_MODE: happy | secrets | hang | crash | ui | malformed | protocol
# Optional FAKE_PI_PIDFILE: write $$ after prompt so tests can assert death.
set -euo pipefail

mode="${FAKE_PI_MODE:-happy}"

write_pidfile() {
  if [[ -n "${FAKE_PI_PIDFILE:-}" ]]; then
    printf '%s\n' "$$" >"$FAKE_PI_PIDFILE"
  fi
}

# Drain stdin for a prompt (or abort).
got_prompt=0
while IFS= read -r line; do
  case "$line" in
    *'"type":"prompt"'*|*'"type": "prompt"'*)
      got_prompt=1
      break
      ;;
    *'"type":"abort"'*|*'"type": "abort"'*)
      printf '%s\n' '{"type":"agent_settled"}'
      exit 0
      ;;
  esac
done

if [[ "$got_prompt" -ne 1 ]]; then
  exit 2
fi

write_pidfile

case "$mode" in
  happy)
    # Split a JSON line across two writes to exercise the byte buffer.
    printf '%s' '{"type":"response","id":"prompt-1","success":true'
    sleep 0.05
    printf '%s\n' '}'
    printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"hello from fake pi\n"}}'
    printf '%s\n' '{"type":"message_end","message":{"usage":{"input":10,"output":5,"cost":{"total":0.001}}}}'
    printf '%s\n' '{"type":"agent_end","messages":[{}]}'
    printf '%s\n' '{"type":"agent_settled"}'
    exit 0
    ;;
  secrets)
    # Emit env dumps / token shapes so workspace run.log redaction is covered.
    printf '%s\n' '{"type":"response","id":"prompt-1","success":true}'
    printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"OPENROUTER_API_KEY=sk-or-v1-SECRETVALUEHERE123\nGITHUB_TOKEN=github_pat_11AAAA_SECRET\n"}}'
    printf '%s\n' '{"type":"message_end","message":{"usage":{"input":1,"output":1}}}'
    printf '%s\n' '{"type":"agent_settled"}'
    exit 0
    ;;
  hang)
    # Never settle. Keep this script as the process image (no exec) so cmdline
    # still contains fake_pi_rpc.sh, and children are real descendants.
    while true; do
      sleep 1
    done
    ;;
  crash)
    printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"boom\n"}}'
    exit 1
    ;;
  ui)
    printf '%s\n' '{"type":"extension_ui_request","id":"ui-1","requestType":"confirm","message":"proceed?"}'
    while true; do
      sleep 1
    done
    ;;
  malformed)
    printf '%s\n' 'NOT JSON AT ALL'
    printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"recovered\n"}}'
    printf '%s\n' '{"type":"agent_settled"}'
    exit 0
    ;;
  protocol)
    printf '%s\n' '{"type":"response","id":"prompt-1","success":false,"error":"bad prompt"}'
    exit 0
    ;;
  *)
    echo "unknown FAKE_PI_MODE=$mode" >&2
    exit 2
    ;;
esac
