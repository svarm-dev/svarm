# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Setup preflight** (`/setup`): live readiness (key source, default model, form-scoped tracker probe), model suggestions after OpenRouter test, single Apply path ([#5](https://github.com/svarm-dev/svarm/pull/5))
- **Dashboard** governance spine: human-wait first, windowed spend/tokens from one summary, busy-first agent roster ([#5](https://github.com/svarm-dev/svarm/pull/5))
- GitHub issue/PR templates and Dependabot for Hex + Actions ([#6](https://github.com/svarm-dev/svarm/pull/6))
- Human-readable agent **tool logs** on the board (unwrap pi/MCP content blocks; no raw Elixir map dumps) ([#23](https://github.com/svarm-dev/svarm/pull/23), [#28](https://github.com/svarm-dev/svarm/issues/28))
- WORKFLOW placeholder `{{issue.source_id}}` for tracker-native issue numbers (e.g. GitHub `#26`) ([#23](https://github.com/svarm-dev/svarm/pull/23))
- Docker: default git author for agent commits (`SVARM_GIT_EMAIL` / `SVARM_GIT_NAME`); `procps` for process cleanup ([#23](https://github.com/svarm-dev/svarm/pull/23))

### Changed

- License: **FSL-1.1-MIT** (Fair Source / source available → MIT after 2 years per version); was MIT
- Public messaging: lead with “control for your agent loop” / human judgment; drop blended-workforce teammate hype from README, homepage, board, and dashboard
- Successful agent runs that leave the tracker in an active status move to **review** once (no endless re-dispatch) ([#23](https://github.com/svarm-dev/svarm/pull/23))
- Run cost prefers **provider-reported USD** when present, then the rate table ([#23](https://github.com/svarm-dev/svarm/pull/23))

### Fixed

- Docker demo seed keeps `demo_*` assignees (Dispatch no longer overwrites them with ProfileRouter → Pi/OpenRouter)
- Dashboard session token totals with negative monotonic timestamps; completed runs without assignee count on the right agent
- Approve/reject gates use the active tracker (Local or GitHub), not a Local-only path ([#19](https://github.com/svarm-dev/svarm/pull/19))
- GitHub board no longer fills **Todo** with pull requests and unlabeled closed issues ([#23](https://github.com/svarm-dev/svarm/pull/23))
- Docker pi runs no longer crash after exit when `pgrep` is missing, and no longer restart the orchestrator on worker DOWN ([#23](https://github.com/svarm-dev/svarm/pull/23))
- GitHub API 403s log the real message and rate-limit headers (not always “rate limited”) ([#23](https://github.com/svarm-dev/svarm/pull/23))
- Usage ledger stores provider cost so OpenRouter spend can show on receipts ([#23](https://github.com/svarm-dev/svarm/pull/23))

### Security

- Redact API keys and tokens from orchestrator crash dumps, board agent lines, and persisted run logs ([#23](https://github.com/svarm-dev/svarm/pull/23))


## [0.1.2] - 2026-07-25

In-app configuration UI, human-wait visibility on the board, and CI for the public repo.

### Added

- **In-app setup** (`/setup`): encrypted Settings store (OpenRouter key, GitHub PAT tracker overlay, default agent model); explicit **Apply** reloads orchestrator config without restart ([#4](https://github.com/svarm-dev/svarm/pull/4))
- Human **wait-state** visibility on the team board and dashboard (when work is blocked on a person) ([#3](https://github.com/svarm-dev/svarm/pull/3))
- GitHub Actions **`mix ci`** workflow on `main` and pull requests

### Fixed

- Boot without a file_system/inotify backend (CI and minimal containers) — WORKFLOW live reload is optional
- pi RPC module shape for Credo strict / Dialyzer under `mix ci`


## [0.1.1] - 2026-07-24

First **public** try path: Docker demo profile, approvals env, journey docs, instance home, `/health`.

### Added

- Docker **demo profile** (`docker compose --profile demo`): auto-seed board, Seed demo button, default approvals Basic Auth
- `APPROVALS_USER` / `APPROVALS_PASSWORD` env → `/approvals` Basic Auth in Docker/prod (clear 404 hint when unset)
- Compose **directory mount** `./svarm-config` + entrypoint copies WORKFLOW/agents templates when missing
- Instance status on `/` (tracker, workflow path, agents, board emptiness)
- README journey split: A demo / B GitHub loop / C harden; screenshots under `docs/screenshots/`
- `GET /health` for Docker HEALTHCHECK
- First-run checklist on empty board; homepage Approvals CTA only when auth is configured
- `priv/workflow_template.github.md` + louder UNCOMMENT FOR GITHUB block on default template
- Operator agent copy-paste guide `docs/agents.md`

### Changed

- Public onboarding: README/GETTING-STARTED match real Docker mounts, approval gate, and agents.toml keys
- Maintainer-only PRODUCT/DESIGN notes no longer shipped in the public tree
- Seed demo available whenever `SVARM_DEMO_ROUTES`/`SVARM_SEED_DEMO` or Mix `dev_routes` is on
- AGENTS.md banner for operators vs coding agents; honesty pass on shipped surface
- Sample `priv/agents/*.toml` removed in favor of docs/agents.md
- Compose **app** / **demo** profiles are mutually exclusive (no port 4000 clash)

### Fixed

- Orchestrator poll loop survives tracker `list_eligible` errors (e.g. GitHub rate limit) instead of MatchError crash
- Path A Docker demo no longer starts the non-demo service on the same host port
- **pi RPC** runner: wall-clock timeout, process-tree cleanup on abort, oversized JSONL line protection, clearer fail-fast when `pi` is missing; operator notes in GETTING-STARTED / `docs/agents.md`

## [0.1.0] - 2026-07-15

Private first cut: self-hosted orchestrator with a LiveView board, local + GitHub trackers, and per-ticket usage tracking. Poll loop inspired by [Symphony](https://github.com/openai/symphony/blob/main/SPEC.md).

### Added

- Poll loop (`reconcile` → `preflight` → fetch → dispatch) with workspace isolation and retry/backoff
- Local SQLite kanban (`KanbanBridge` / Ecto) and **GitHub Issues** tracker behind `Svarm.Tracker`
- Runner behaviour with **CLI** and **pi RPC** adapters; agent definitions in `priv/agents.toml`
- **OpenRouter** provider adapter; secrets via environment / `.env` only (never in config files)
- Append-only **usage ledger** with per-task cost breakdown on the team board
- **WORKFLOW.md** contract (tracker states, approvals, prompts) plus template under `priv/`
- Human-in-the-loop **approval gates** (`pending_approval`, approve/reject UI)
- LiveView **Team Board** (`/board`): PubSub task updates, streaming agent logs, orchestrator status
- Board UX: agent identity, cost chips, activity bar, empty-board onboarding, keyboard selection (`j`/`k`, `Esc`), `?task=` deep links, inline approvals
- Profile-based task routing (`ProfileRouter`) and priority-based task dependency wiring
- Demo path without API keys: `mix svarm.demo`, dev **Seed demo** on a running server
- Docker / docker-compose packaging and `mix svarm.run` goal → decompose → dispatch flow
- Operator docs (`README`, `GETTING-STARTED`) and coding-agent conventions (`AGENTS.md`)

Shipped surface in this cut: **local board + GitHub Issues + pi/CLI + OpenRouter**. Further trackers/providers are extension points, not included here.

### Fixed

- OpenRouter HTTP headers limited to ASCII (non-ASCII product names broke requests)
- Usage display crashes on empty breakdowns; free-model / source field handling
- Orchestrator and board stability around run lifecycle (e.g. `mix svarm.run` teardown, BoardLive assigns, Issue struct access in run metadata)
- Idempotent CreateTasks migration for existing databases

### Security

- Agent credentials and API keys must come from the environment; never written into task metadata, PubSub events, or tracked config files

[Unreleased]: https://github.com/svarm-dev/svarm/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/svarm-dev/svarm/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/svarm-dev/svarm/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/svarm-dev/svarm/releases/tag/v0.1.0
