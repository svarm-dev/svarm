#!/bin/sh
# Runtime smoke test for the Svärm image.
#
# Checks the two things a broken Dockerfile silently loses: the release under
# /app, and the agent toolchain beside it. CI runs this against a freshly built
# image so a runtime stage that is missing Elixir stdlib apps (or the compiler
# needed for native deps) fails the build instead of failing an agent later.
#
# Usage:
#   docker run --rm --entrypoint sh \
#     -v "$PWD/docker/smoke-test.sh:/tmp/smoke-test.sh:ro" <image> /tmp/smoke-test.sh
set -e

echo "== release =="
test -x /app/bin/svarm || { echo "missing /app/bin/svarm" >&2; exit 1; }

echo "== toolchain versions =="
mix --version
elixir --version

echo "== Elixir stdlib apps =="
elixir -e '
apps = [EEx, ExUnit, Logger, Mix, IEx]

Enum.each(apps, fn app ->
  unless Code.ensure_loaded?(app), do: raise("missing stdlib app: #{inspect(app)}")
end)

if EEx.eval_string("<%= 1 + 1 %>") != "2", do: raise("EEx does not evaluate")

require Logger
Logger.info("EEx, ExUnit, Logger, Mix and IEx load")
'

echo "== mix project (new + test) =="
cd /tmp
rm -rf smoke
mix new smoke >/dev/null
cd smoke
mix test

echo "== native dep compile =="
sed -i 's|# {:dep_from_hexpm, "~> 0.3.0"},|{:exqlite, "~> 0.43"},|' mix.exs
grep -q '{:exqlite, "~> 0.43"}' mix.exs || { echo "could not add exqlite dep" >&2; exit 1; }
mix local.rebar --force >/dev/null
mix deps.get >/dev/null
MIX_ENV=test mix deps.compile >/dev/null
test -d _build/test/lib/exqlite/ebin || { echo "exqlite NIF did not compile" >&2; exit 1; }

echo "toolchain ok"
