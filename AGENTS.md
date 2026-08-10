# AGENTS.md

> **Audience:** AI coding agents **editing this repository**, and humans reviewing those changes.  
> **Operators trying Svärm:** start at [GETTING-STARTED.md](GETTING-STARTED.md) / [README.md](README.md).  
> “Agent” here means the coding tool (pi, Claude Code, …) changing this codebase — not a swarm member on the board.


Instructions for coding agents working in **Svärm** (`svarm`). Human-oriented docs: [README.md](README.md), [GETTING-STARTED.md](GETTING-STARTED.md).

## Project overview

Svärm is a **self-hosted control plane** for external coding agents on your tickets (Symphony-compatible poll/reconcile). It dispatches agents (pi, Claude Code, etc.) from a LiveView board, governed by a WORKFLOW.md contract. The external agent is **prompted** (via WORKFLOW) to branch/push/`gh pr create`; tickets land in `review` with a cost receipt; humans keep merge. Not a lights-off factory or embedded multi-agent runtime.

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
│   │   ├── agent_runner.ex       # Runner facade: load agents, resolve adapter, dispatch
│   │   ├── runner.ex             # Runner helpers (env, GitHub token)
│   │   ├── runner/cli.ex         # CLI runner — Port.open / process kill tree
│   │   ├── runner/pi_rpc.ex      # pi RPC runner — Port.open / process kill tree
│   │   ├── dispatch.ex           # Goal → kanban decomposition
│   │   ├── decompose.ex          # LLM-powered task breakdown
│   │   ├── kanban_bridge.ex      # Task CRUD via Ecto (GenServer API)
│   │   ├── kanban/task.ex        # Ecto schema for tasks
│   │   ├── repo.ex               # Ecto Repo (SQLite)
│   │   ├── workspace.ex          # Per-task workspace directories (path isolation)
│   │   ├── workflow.ex           # WORKFLOW.md parsing (Config/Render/Store)
│   │   ├── approval.ex           # First-run human-in-the-loop gating
│   │   ├── board.ex              # Read API for the dashboard
│   │   ├── events.ex             # PubSub broadcasts to LiveView
│   │   ├── profile_router.ex     # Task → agent routing
│   │   └── application.ex        # Supervision tree
│   └── svarm_web/                # Phoenix web layer (mostly read-only; approvals mutate)
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

The web layer is mostly a **read-only observer** of orchestration. Exception: `ApprovalsController` and board approve/reject events call `Svarm.Approval`, which mutates tracker state.

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
│                      │    │  (facade: load/resolve)   │
│  Depends on:         │    │                            │
│  • Svarm.Tracker     │    │  Shell-out lives in:       │
│  • Svarm.Runner      │    │  Runner.Cli / Runner.PiRPC │
│  • KanbanBridge      │    │  (Port.open, kill tree)    │
│  • Workflow.Store    │    └──────────────────────────┘
│  • Approval          │    ┌──────────────────────────┐
│  • Events            │    │  Svarm.Workspace          │
│  • Dispatch          │    │  (per-ticket directories) │
│  • Decompose         │    │  Path escape guard        │
└──────────────────────┘    └──────────────────────────┘
```

**Rules:**
- **Orchestrator calls adapters, not implementations** — depends on `Svarm.Tracker` (behaviour), never `Svarm.Tracker.GitHub`.
- **Web layer never calls AgentRunner or Workspace** — reads state through `Board` and `Orchestrator.status/0`. **Exception:** approve/reject via `Approval` (ApprovalsController + BoardLive).
- **Shell-out lives in Runner adapters** — `Port.open`, process kill tree, and related `System.cmd` for agent processes live in `Runner.Cli` / `Runner.PiRPC`. `AgentRunner` is the facade (load agents, resolve adapter, dispatch).
- **KanbanBridge is the task DB path** — all task Ecto queries go through `KanbanBridge`. Other Repo-backed contexts are allowed for their own domains: `Usage`/`RunLog`/`Settings` (not task state).
- **Events is the cross-boundary side channel** — backend → web communication is PubSub, not direct calls.
- **Approval uses the active tracker** — same settings/workflow resolve as the orchestrator (Local or GitHub), never a hardcoded Local-only path.

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
| `mix ci` | compile, format check, test, credo --strict, dialyzer, `deps.audit` (mix_audit), sobelow --exit, ex_dna, reach |

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

### Skills and agent context

Split of responsibilities (see [agents.md](https://agents.md) and [Agent Skills](https://agentskills.io/home)):

- **`AGENTS.md` (this file)** — always-on project memory: architecture, commands, boundaries, security, testing rules. Closest AGENTS.md wins; chat overrides all.
- **Skills** — on-demand playbooks for specialized work (progressive disclosure: name/description always, full `SKILL.md` only when activated). Prefer reusable domain skills over repo-specific clones of the same material.

Do **not** put Svärm architecture rules only in skills. If every edit should know it, it belongs here.

**Tooling skills (global packages):**
- **`elixir` / `elixir-web`** (pi-elixir) — BEAM runtime tools and default Elixir routing.
- **`phx-*` / `ecto-*` / `lv-*` / domain refs** — from project package `claude-elixir-phoenix` (Iron Laws, review/investigate workflows). Invoke with `/skill:phx-review`, `/skill:phx-investigate`, etc.
- **`impeccable`** — UI craft when the task is frontend.
- **`ponytail`** — minimal diffs / YAGNI.

Svärm product law always overrides generic Phoenix advice when they conflict (SQLite-only, KanbanBridge-only DB access, Runner.Cli/PiRPC shell-out only, no Postgres).

## Progress bus (Maino ↔ coding agent)

Human chat is **not** shared context between Hermes (Maino) and the coding harness (Pi / Grok Build / …). Use durable surfaces:

| Surface | For |
|---------|-----|
| **[STATUS.md](STATUS.md)** | Code snapshot — read at session start; update at session end |
| **GitHub Issues + PRs** | All code work units (never chat-only tasks) |
| **Vault `Ops/Agent Desk.md`** | Non-code handoffs (strategy/launch) — if you have vault access |

**Start of every coding session:** read `STATUS.md`, then `gh issue view` on your claim.  
**End of session / when opening a PR:** refresh STATUS **Snapshot** + one **Session log** line.  
**Blocked on human:** STATUS **Blocked** line + issue/PR comment — do not rely on Telegram.

## GitHub issue → PR workflow (coding agents)

**Role split:** Hermes shapes issues/ADRs; **coding agent implements**; **human merges**. Do not merge PRs unless the human explicitly asks.

**Required tooling:** `gh` installed and authenticated (`gh auth status`). Prefer `gh` over raw REST. Repo remote is **`origin` → `github.com/svarm-dev/svarm`** only.

### Loop

1. **Orient** — read [STATUS.md](STATUS.md) (focus + blockers).
2. **Intake** — `gh issue view N` (treat acceptance criteria as law). Optional: comment that you are taking it.
3. **Sync** — `git fetch origin && git checkout main && git pull --ff-only origin main`
4. **Branch** — conventional short name from main:
   - `fix/…` · `feat/…` · `docs/…` · `refactor/…` · `test/…` · `ci/…`
5. **Implement** — only what the issue AC requires. No drive-by refactors.
6. **Verify** — `mix precommit` before push (larger changes: `mix ci` when practical).
7. **Push + PR**
   ```bash
   git push -u origin HEAD
   gh pr create --title "type: short description" --body "$(cat <<'EOF'
   ## Summary
   - …

   ## How tested
   - [ ] mix precommit / relevant tests
   - [ ] …

   ## For Maino
   - (only if strategy / fence / positioning needs a non-coder — else delete this section)

   Closes #N
   EOF
   )"
   ```
8. **CI** — `gh pr checks` (or `gh pr checks --watch`). On red: `gh run view <id> --log-failed` → fix → push. **Max 3 fix loops**, then stop and report blocked with logs/PR URL.
9. **STATUS** — update [STATUS.md](STATUS.md) Snapshot + Session log (same PR or immediate follow-up).
10. **Hand off** — reply with PR URL, summary, residual risk. **Do not merge.**

### Hard rules

| Do | Don't |
|----|--------|
| One issue → one branch → one PR | Expand scope past the issue AC |
| `Closes #N` (or `Fixes #N`) in the PR body | Close the issue manually mid-work |
| Comment on the issue if blocked | Invent follow-up work “while here” |
| Keep CI green before pinging the human | Merge to `main` |
| Commit only intentional paths | Commit `.env`, PEMs, keys, local config |
| Update STATUS.md after meaningful work | Use human chat as the only handoff |

### PR title / commits

Conventional Commits: `type(scope): summary` — types `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `ci`, `perf`.

### When the issue includes docs AC

Ship docs in the **same PR** as the code (example: issue #17 requires AGENTS/README honesty with the Approval fix). Do not open a sibling “docs later” PR unless the human says so.

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

## Usage / governance

- **Usage ledger is append-only** — never update or delete ledger rows; correct with new records.
- **Store tokens + model_id; compute cost at query time** from rate tables (not a frozen dollar column as source of truth).
- **Budget checks belong in preflight/dispatch**, not only on dashboards after spend. Hard caps (`SVARM_BUDGET_*` / WORKFLOW `budget.*`) hard-stop **new** spawns; estimated spend counts toward the cap; in-flight runs are not killed.
- **Flag estimates** — never present estimated costs as exact.

## Security

- **Never commit API keys or auth tokens.** Agents expect credentials from the operator's environment (`GITHUB_TOKEN`, `OPENROUTER_API_KEY`, etc.).
- **Secrets never appear in task metadata, logs, or PubSub messages.**
- **Workspace paths are root-bounded** — `Workspace.ensure/2` validates paths stay within the configured root (directory isolation / path-escape guard, not OS sandbox). Never bypass this guard.
- **Agent shell commands are high trust** — agents run arbitrary commands in isolated workspace directories. The first-run approval gate (`approval.*` in WORKFLOW.md) prevents unattended execution until the operator explicitly approves.
- **Production approvals** require Basic Auth: `config :svarm, approvals_auth: %{username: ..., password: ...}`. Dev mode uses `dev_routes: true` for unauthenticated access. Board high-trust mutations use a **TTL-bound** session stamp (`board_auth_at`, default 8h / `BOARD_AUTH_TTL_SECONDS`) — not a lifetime boolean.
- **Config secrets** use `System.get_env/1` or `System.fetch_env!/1` in `runtime.exs` — never hardcoded in `.exs` files checked into git.

## What not to do

- **Do not add Postgres** — SQLite via Ecto is the project standard. Postgres is a managed-tier option for the distant future, not now.
- **Do not replace KanbanBridge with an external tracker** without going through the adapter behaviour (`Svarm.Tracker`).
- **Do not add Ecto queries for tasks outside KanbanBridge** — task CRUD stays on `KanbanBridge`. `Usage`/`RunLog`/`Settings` own their tables.
- **Do not shell out from anywhere except Runner adapters** — `Port.open` / agent process kill tree live in `Runner.Cli` and `Runner.PiRPC` only (AgentRunner is the facade).
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
