#!/bin/sh
# Minimal CLI agent peer for Runner.Cli smoke tests (no API keys, no sleeps).
# Usage: fake_cli_agent.sh <mode>
#   ok   — print a line and exit 0
#   fail — print a line and exit 1
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
  *)
    echo "fake-cli: unknown mode: $mode" >&2
    exit 2
    ;;
esac
