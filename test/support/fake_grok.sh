#!/bin/sh
# Stub Grok Build CLI for CI (no live `grok` / XAI_API_KEY).
# Accepts the documented headless flags and prints board-visible output
# plus a JSON usage line the CLI runner can parse.
set -e

prompt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p | --single)
      shift
      prompt="${1:-}"
      ;;
    --no-auto-update | --always-approve | --no-alt-screen) ;;
    --output-format)
      shift
      ;;
    -m | --model)
      shift
      ;;
    --cwd)
      shift
      ;;
    *)
      # Trailing prompt (Svärm appends the rendered WORKFLOW prompt last).
      prompt="$1"
      ;;
  esac
  shift || true
done

echo "grok-build: headless ok"
if [ -n "$prompt" ]; then
  echo "grok-build: received prompt (${#prompt} bytes)"
fi
echo '{"usage":{"prompt_tokens":12,"completion_tokens":8}}'
exit 0
