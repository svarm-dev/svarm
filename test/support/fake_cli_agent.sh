#!/bin/sh
# Minimal CLI agent peer for Runner.Cli smoke tests (no API keys).
# Usage: fake_cli_agent.sh <mode>
#   ok   — print a line and exit 0
#   fail — print a line and exit 1
#   hang — long-lived descendant; optional FAKE_CLI_PIDFILE writes the child pid
set -e
mode="${1:-ok}"

case "$mode" in
  ok)
    echo "fake-cli: ok"
    exit 0
    ;;
  fail)
    echo "fake-cli: fail"
    exit 1
    ;;
  hang)
    sleep 999999 &
    child=$!
    if [ -n "${FAKE_CLI_PIDFILE:-}" ]; then
      printf '%s\n' "$child" >"$FAKE_CLI_PIDFILE"
    fi
    wait "$child"
    ;;
  *)
    echo "fake-cli: unknown mode: $mode" >&2
    exit 2
    ;;
esac
