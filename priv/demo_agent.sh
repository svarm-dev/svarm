#!/bin/sh
# Staged demo runner for /board — streams lines with sleeps (research → code → docs).
set -e
stage="${1:-research}"

case "$stage" in
  research)
    echo "[research] Scoping goal and constraints…"
    sleep 3
    echo "[research] Drafting acceptance criteria…"
    sleep 4
    echo "[research] Out-of-scope notes captured."
    sleep 2
    echo "[research] Phase complete."
    ;;
  code)
    echo "[code] Opening workspace layout…"
    sleep 2
    echo "[code] Applying core change (stub)…"
    sleep 5
    echo "[code] Running quick self-check…"
    sleep 4
    echo "[code] Implementation pass done."
    ;;
  docs)
    echo "[docs] Summarizing what changed…"
    sleep 3
    echo "[docs] Writing operator notes to run.log…"
    sleep 4
    echo "[docs] Documentation pass complete."
    ;;
  *)
    echo "unknown demo stage: $stage"
    exit 1
    ;;
esac