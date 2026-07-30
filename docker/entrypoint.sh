#!/bin/sh
# Auto-generate SECRET_KEY_BASE when not provided (demo/single-command quickstart).
# Copy config templates into the mounted config dir when missing.
set -e

if [ -z "$SECRET_KEY_BASE" ]; then
  export SECRET_KEY_BASE=$(openssl rand -base64 48)
  echo "svarm: generated SECRET_KEY_BASE (set in .env for persistence across restarts)"
fi

CONFIG_DIR="${SVARM_CONFIG_DIR:-/app/config}"
TEMPLATES_DIR="${SVARM_TEMPLATES_DIR:-/app/templates}"

mkdir -p "$CONFIG_DIR" /app/data /app/tmp

# Docker demo profile: always refresh WORKFLOW from template so approval gates
# (research/docs trusted, code untrusted) and local tracker match the release.
if [ "${SVARM_SEED_DEMO:-}" = "1" ] || [ "${SVARM_SEED_DEMO:-}" = "true" ]; then
  if [ -f "$TEMPLATES_DIR/WORKFLOW.md" ]; then
    cp "$TEMPLATES_DIR/WORKFLOW.md" "$CONFIG_DIR/WORKFLOW.md"
    echo "svarm: demo profile — refreshed WORKFLOW.md from template"
  fi
fi

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

# Agent commits need an identity (container has none by default).
git config --global user.email "${SVARM_GIT_EMAIL:-svarm-bot@users.noreply.github.com}"
git config --global user.name "${SVARM_GIT_NAME:-Svärm Agent}"

exec "$@"
