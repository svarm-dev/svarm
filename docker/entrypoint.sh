#!/bin/sh
# Copy config templates into the mounted config dir when missing.
# Prevents Docker file-mount footguns (missing host file → directory named WORKFLOW.md).
set -e

CONFIG_DIR="${SVARM_CONFIG_DIR:-/app/config}"
TEMPLATES_DIR="${SVARM_TEMPLATES_DIR:-/app/templates}"

mkdir -p "$CONFIG_DIR" /app/data /app/tmp

if [ ! -f "$CONFIG_DIR/WORKFLOW.md" ]; then
  if [ -f "$TEMPLATES_DIR/WORKFLOW.md" ]; then
    cp "$TEMPLATES_DIR/WORKFLOW.md" "$CONFIG_DIR/WORKFLOW.md"
    echo "svarm: created $CONFIG_DIR/WORKFLOW.md from template (edit tracker owner/repo for GitHub)"
  else
    echo "svarm: warning — no WORKFLOW.md template at $TEMPLATES_DIR/WORKFLOW.md" >&2
  fi
fi

if [ ! -f "$CONFIG_DIR/agents.toml" ]; then
  if [ -f "$TEMPLATES_DIR/agents.toml" ]; then
    cp "$TEMPLATES_DIR/agents.toml" "$CONFIG_DIR/agents.toml"
    echo "svarm: created $CONFIG_DIR/agents.toml from template"
  else
    echo "svarm: warning — no agents.toml template at $TEMPLATES_DIR/agents.toml" >&2
  fi
fi

export SVARM_WORKFLOW_PATH="${SVARM_WORKFLOW_PATH:-$CONFIG_DIR/WORKFLOW.md}"
export SVARM_AGENTS_PATH="${SVARM_AGENTS_PATH:-$CONFIG_DIR/agents.toml}"

exec "$@"
