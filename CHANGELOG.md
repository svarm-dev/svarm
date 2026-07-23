# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First public try path (planned tag **v0.1.1**). See [docs/release.md](docs/release.md).

### Added

- Docker **demo profile** (`docker compose --profile demo`): auto-seed board, Seed demo button, default approvals Basic Auth
- `APPROVALS_USER` / `APPROVALS_PASSWORD` env → `/approvals` Basic Auth in Docker/prod (clear 404 hint when unset)
- Compose **directory mount** `./svarm-config` + entrypoint copies WORKFLOW/agents templates when missing
- Instance status on `/` (tracker, workflow path, agents, board emptiness)
- README journey split: A demo / B GitHub loop / C harden; screenshot slots under `docs/screenshots/`
- `GET /health` for Docker HEALTHCHECK (force_ssl path excluded)
- First-run checklist on empty board; homepage Approvals CTA only when auth is configured
- `priv/workflow_template.github.md` + louder UNCOMMENT FOR GITHUB block on default template
- Operator agent copy-paste guide `docs/agents.md`; public-cut runbook `docs/release.md`

### Changed

- Public onboarding: README/GETTING-STARTED match real Docker mounts, approval gate, and agents.toml keys
- Maintainer-only PRODUCT/DESIGN notes no longer shipped in the public tree
- Seed demo available whenever `SVARM_DEMO_ROUTES`/`SVARM_SEED_DEMO` or Mix `dev_routes` is on
- AGENTS.md banner for operators vs coding agents; honesty pass on shipped surface
- Sample `priv/agents/*.toml` removed in favor of docs/agents.md

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
