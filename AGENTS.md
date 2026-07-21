# AGENTS.md

> **Audience:** AI coding agents **editing this repository**, and humans reviewing those changes.  
> **Operators trying Svärm:** start at [GETTING-STARTED.md](GETTING-STARTED.md) / [README.md](README.md).  
> “Agent” here means the coding tool (pi, Claude Code, …) changing this codebase — not a swarm member on the board.


Instructions for coding agents working in **Svärm** (`svarm`). Human-oriented docs: [README.md](README.md), [GETTING-STARTED.md](GETTING-STARTED.md).

## Project overview

Svärm is a **Symphony-compatible** autonomous dev-team orchestrator and blended workforce platform. It dispatches coding agents (pi, Claude Code, etc.) to work on tickets from a kanban board, governed by a WORKFLOW.md contract.

- **Stack:** Elixir 1.20.2 / OTP 29 (`.mise.toml`), Phoenix 1.8, Ecto 3.14 with `ecto_sqlite3`, Tailwind CSS + daisyUI.
- **Database:** SQLite via Ecto (`Svarm.Repo`). Single-file, no daemon. Postgres is a future managed-tier option, not now.
- **HTTP:** Use **`Req`** only. Do not add `:httpoison`, `:tesla`, or `:httpc`.
- **Spec reference:** [Symphony SPEC](https://github.com/openai/symphony/blob/main/SPEC.md). Svärm adopts the poll/reconcile loop (§8), workspace isolation (§9), and WORKFLOW.md contract (§5) without requiring Codex app-server or Linear.

## Repository structure

```
svarm/
├── lib/
│   ├── svarm/                    # Orchestration backend
│   │   ├── orchestrator.ex       # GenServer poll loop (the brain)
│   │   ├── agent_runner.ex       # System.cmd dispatch, Port streaming
│   │   ├── dispatch.ex           # Goal → kanban decomposition
│   │   ├── decompose.ex          # LLM-powered task breakdown
│   │   ├── kanban_bridge.ex      # Task CRUD via Ecto (GenServer API)
│   │   ├── kanban/task.ex        # Ecto schema for tasks
│   │   ├── repo.ex               # Ecto Repo (SQLite)
│   │   ├── workspace.ex          # Per-task sandbox directories
│   │   ├── workflow.ex           # WORKFLOW.md parsing (Config/Render/Store)
│   │   ├── approval.ex           # First-run human-in-the-loop gating
│   │   ├── board.ex              # Read API for the dashboard
│   │   ├── events.ex             # PubSub broadcasts to LiveView
│   │   ├── profile_router.ex     # Task → agent routing
│   │   └── application.ex        # Supervision tree
│   └── svarm_web/                # Phoenix web layer (read-only observer)
│       ├── live/board_live.ex    # Team board LiveView
│       ├── controllers/          # Page, approvals, demo seed
│       ├── components/           # CoreComponents, layouts
│       ├── plugs/                # Approvals auth
│       ├── router.ex
│       └── endpoint.ex
├── priv/
│   ├── agents.toml               # Agent definitions (name, command, env)
│   ├── providers.toml            # LLM provider endpoints (future)
│   ├── workflow_template.md      # Fallback WORKFLOW.md
│   └── repo/migrations/          # Ecto migrations
├── config/                       # config.exs, dev/test/prod/runtime.exs
├── test/                         # ExUnit tests (mirrors lib/ structure)
│   └── support/                  # ConnCase, LiveCase
├── assets/                       # Tailwind CSS, JS hooks
├── docs/                         # User-facing guides (GitHub App setup, …)
└── WORKFLOW.md                   # Optional repo-owned workflow config
```

## Architecture boundaries

The web layer is a **read-only observer** of orchestration. It never mutates state directly.

```
┌─────────────────────────────────────────────────────────────┐
│  SvarmWeb (Phoenix)                                         │
│  BoardLive → Board.list_tasks, Orchestrator.status (reads)  │
│  ApprovalsController → Approval (reads + approve/reject)    │
│  Subscribes to Events (PubSub) for streaming agent output   │
│  NEVER calls AgentRunner, Dispatch, Decompose, Workspace    │
└──────────────┬──────────────────────────┬───────────────────┘
               │ GenServer calls          │ PubSub
               ▼                          ▼
┌──────────────────────┐    ┌──────────────────────────┐
│  Svarm.Orchestrator  │◄───│  Svarm.KanbanBridge       │
│  (GenServer)         │    │  (GenServer → Ecto Repo)  │
│                      │    └──────────────────────────┘
│  Tick: reconcile →   │
│  preflight → fetch   │    ┌──────────────────────────┐
│  eligible → dispatch │    │  Svarm.AgentRunner        │
│                      │    │  (System.cmd, Port)       │
│  Depends on:         │    │                            │
│  • Svarm.Tracker     │    │  ONLY module that shells  │
│  • Svarm.Runner      │    │  out to external processes│
│  • KanbanBridge      │    └──────────────────────────┘
│  • Workflow.Store    │
│  • Approval          │    ┌──────────────────────────┐
│  • Events            │    │  Svarm.Workspace          │
│  • Dispatch          │    │  (sandbox directories)    │
│  • Decompose         │    │  Path escape guard        │
└──────────────────────┘    └──────────────────────────┘
```

**Rules:**
- **Orchestrator calls adapters, not implementations** — depends on `Svarm.Tracker` (behaviour), never `Svarm.Tracker.GitHub`.
- **Web layer never calls AgentRunner or Workspace** — reads state through `Board` and `Orchestrator.status/0`.
- **Only AgentRunner shells out** — `System.cmd`, `Port.open`, `File.cd` live exclusively in `agent_runner.ex`.
- **Only KanbanBridge touches the DB** — all Ecto queries go through `KanbanBridge` GenServer calls. Other modules never import `Ecto.Query` or call `Svarm.Repo` directly.
- **Events is the cross-boundary side channel** — backend → web communication is PubSub, not direct calls.

## Setup and commands

```bash
mise install              # if using mise
mix setup                 # deps + assets
mix phx.server            # dev server → http://localhost:4000
mix test                  # full suite
mix test test/path/to_test.exs
mix test --failed
mix svarm.demo            # isolated end-to-end demo (no API keys, tmp DB)
mix svarm.run "build a CLI tool"  # decompose goal → dispatch (needs LLM key)
```

**Quality gates:**

| Command | What it checks |
|---------|---------------|
| `mix precommit` | compile (--warnings-as-errors), unused deps, format, full test suite |
| `mix ci` | precommit + credo --strict + dialyzer + ex_dna + reach |

**Before finishing any change:** run `mix precommit`. Fix all failures. For larger changes, run `mix ci`.

**Ecto commands:**
```bash
mix ecto.migrate          # run pending migrations (also runs at app startup)
mix ecto.gen.migration name  # generate a new migration
```

**Demo task note:** `mix svarm.demo` sets `Application.put_env(:svarm, Svarm.Repo, database: tmp_path)` before app start — it runs against an isolated temp database. The phx.server board uses `~/.svarm/kanban/kanban.db`.

## Coding agent harness: pi-elixir

Svärm is developed with **pi** and the **pi-elixir** extension. pi-elixir provides BEAM-native tools: `elixir_eval` for runtime inspection, `elixir_ast_search`/`elixir_ast_replace` for structural code changes, and LSP for editor semantics.

**This repo does not need `:pi_bridge` in `mix.exs`.** Current pi-elixir ships a bundled isolated control-plane bridge. Start pi from this project directory with Elixir/Mix on PATH (via mise).

```text
/elixir:status    # control bridge + project worker
/elixir:doctor    # diagnose setup issues
/elixir:restart   # after fixing Mix/compile errors
```

### Tool usage

Use **lowercase** pi tools: `read`, `edit`, `write`, `bash`. Do not use `Read`, `Edit`, `Grep`, `Glob` — these are not registered and will fail.

For large outputs, use `ctx_execute` / `ctx_execute_file` instead of `bash`. For multi-command batches, use `ctx_batch_execute`.

### Daily workflow

1. **Runtime truth → `elixir_eval`** — prefer the running system over guessing from files. Use `target: "application"` to inspect orchestrator state, `target: "project"` for code/docs without booting the app. After file edits, use `reload: true`. Example: `Svarm.Orchestrator.status()`, `Svarm.KanbanBridge.list_tasks()`.

2. **Elixir shape → `elixir_ast_search` / `elixir_ast_replace`** — structural search/refactor, not regex. Use `dryRun: true` on replaces first.

3. **Before large diffs → eval orientation** — `AST.diff(changed: true)` and `CodeMap.reflect(changed: true)`, then read only relevant modules or `git diff` hunks.

4. **Small edits → host `read` / `edit`**. **Final verification → shell**: `mix precommit`.

### Skills

Load skills on-demand by reading their `SKILL.md` when the task matches. Do not preload them all.

**From pi-elixir (general):**
- **`elixir`** — default for `.ex`/`.exs`, Mix, OTP, backend bugs.
- **`elixir-web`** — LiveView, HEEx, assets, Tailwind, UI verification. Use when UI is the primary task.

## Elixir conventions

- **Write for the public repo** — @moduledoc, @doc, and comments should be understandable to someone reading the GitHub repo for the first time. Never reference private maintainer docs, plan step numbers, or build priorities that aren't in the public repo. Describe what the module IS and what it DOES, not its history.
- **Pattern match in function heads** — prefer `def process(%{status: :active} = task)` over `if task.status == :active` inside a single clause.
- **`with` for happy path** — chain `{:ok, _}` tuples; the else block handles failures.
- **Tagged tuples for results** — `{:ok, value}` / `{:error, reason}`. Never bare `:ok`/`:error` atoms or string error messages.
- **Rescue only for external code** — rescue `ErlangError`, `File.Error`, `Jason.DecodeError`. Never rescue `RuntimeError`, `ArgumentError`, `KeyError` — those are programmer bugs that should crash.
- **No bare rescue** — `rescue _ -> ...` swallows bugs. List specific modules: `rescue e in [Jason.DecodeError, ArgumentError] -> ...`.
- **No dynamic atom creation** — agent names, task IDs, workspace keys are strings. Never `String.to_atom/1` on external input.
- **Supervise all long-lived processes** — every GenServer/Agent must be in the supervision tree.
- **GenServer.call timeout** — default 5 seconds. Long-running calls need explicit timeouts.
- **Structs for public APIs, maps for boundaries** — `KanbanBridge` returns plain maps with atom keys so callers don't depend on Ecto structs. Internally, use Ecto schemas.
- **Pipeline style** — use `|>` liberally. Keep pipelines under ~5 steps; extract named functions for longer chains.
- **Module naming** — `Svarm.ModuleName` (CamelCase). File: `lib/svarm/module_name.ex` (snake_case).
- **Aliases at the top** — `alias Svarm.{Foo, Bar, Baz}` grouped by domain.

## Testing

```bash
mix test                          # full suite
mix test test/svarm/orchestrator_test.exs
mix test --only <tag>
```

- Tests that touch the database use a temp SQLite database (configured in `config/test.exs`). No sandbox needed — each test run gets its own DB.
- Database-touching tests use `async: false` (SQLite serializes writes).
- Migrations run automatically at app startup — tests don't need explicit migration setup.
- **Add tests for new behaviour, not implementation details.** Test the GenServer API, not internal helper functions.
- Use `SvarmWeb.ConnCase` for controller tests, `SvarmWeb.LiveCase` for LiveView tests.
- The demo agent (`demo_*` assignees in `priv/agents.toml`) runs a shell script that simulates agent output — no API keys needed in tests.

## Security

- **Never commit API keys or auth tokens.** Agents expect credentials from the operator's environment (`GITHUB_TOKEN`, `OPENROUTER_API_KEY`, etc.).
- **Secrets never appear in task metadata, logs, or PubSub messages.**
- **Workspace paths are sandboxed** — `Workspace.ensure/2` validates paths stay within the configured root. Never bypass this guard.
- **Agent shell commands are high trust** — agents run arbitrary commands in isolated workspace directories. The first-run approval gate (`approval.*` in WORKFLOW.md) prevents unattended execution until the operator explicitly approves.
- **Production approvals** require Basic Auth: `config :svarm, approvals_auth: %{username: ..., password: ...}`. Dev mode uses `dev_routes: true` for unauthenticated access.
- **Config secrets** use `System.get_env/1` or `System.fetch_env!/1` in `runtime.exs` — never hardcoded in `.exs` files checked into git.

## What not to do

- **Do not add Postgres** — SQLite via Ecto is the project standard. Postgres is a managed-tier option for the distant future, not now.
- **Do not replace KanbanBridge with an external tracker** without going through the adapter behaviour (`Svarm.Tracker`).
- **Do not add Ecto queries outside KanbanBridge** — all database access goes through the `KanbanBridge` GenServer.
- **Do not shell out from anywhere except AgentRunner** — `System.cmd`, `Port.open`, `File.cd` are AgentRunner's exclusive domain.
- **Do not expand scope to Symphony Codex app-server streaming** unless explicitly asked — v1 is poll/reconcile + WORKFLOW.md, not Codex app-server.
- **Do not add `:httpoison`, `:tesla`, or `:httpc`** — use `Req` for all HTTP.
- **Do not add `:pi_bridge` to mix.exs** — pi-elixir bundles its own bridge. This is an outdated install path.

## When things break

| Symptom | Action |
|--------|--------|
| Mix cwd not found | Open pi in `svarm` (this repo) |
| Elixir not on PATH | Use mise/shell where `mix` works; restart pi |
| Control bridge / worker offline | `/elixir:doctor`, fix compile/runtime error, `/elixir:restart` |
| Stale code in eval | `elixir_eval` with `reload: true`, or `mix compile` then re-eval |
| "no such table: tasks" | Run `mix ecto.migrate` or restart app (runs on startup) |
| Old docs mention `pi_bridge` | Ignore — upgrade `pi install npm:pi-elixir` to current |
| Agent spawn failed | Check agent command in `priv/agents.toml` is on PATH |
| Demo task config | `mix svarm.demo` uses tmp DB; `/board` uses `~/.svarm/kanban/kanban.db` |
