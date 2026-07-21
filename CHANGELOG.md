# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-15

First cut of Svärm: self-hosted Symphony-compatible orchestrator with a LiveView board, pluggable adapters, and per-ticket usage tracking.

### Added

- Symphony-style poll loop (`reconcile` → `preflight` → fetch → dispatch) with workspace isolation and retry/backoff
- Local SQLite kanban (`KanbanBridge` / Ecto) and **GitHub Issues** tracker adapter behind `Svarm.Tracker`
- Runner behaviour with **CLI** and **pi RPC** adapters; agent definitions in `priv/agents.toml`
- Provider registry with **OpenRouter** adapter; env-based secrets (no keys in config files)
- Append-only **usage ledger** with per-task cost breakdown on the team board
- **WORKFLOW.md** contract (tracker states, approvals, prompts) plus template under `priv/`
- Human-in-the-loop **approval gates** (`pending_approval`, approve/reject UI)
- LiveView **Team Board** (`/board`): PubSub task updates, streaming agent logs, orchestrator status
- Stage 1 board UX: agent identity, cost chips, at-a-glance activity, empty-board onboarding, keyboard selection (`j`/`k`, `Esc`), `?task=` deep links, inline approvals
- Profile-based task routing (`ProfileRouter`) and priority-based task dependency wiring
- Demo path without API keys: `mix svarm.demo`, dev **Seed demo** on a running server
- Docker / docker-compose packaging and `mix svarm.run` goal → decompose → dispatch flow
- Project agent docs (`AGENTS.md`, README)

### Fixed

- OpenRouter HTTP headers limited to ASCII (non-ASCII product names broke requests)
- Usage display crashes on empty breakdowns; free-model / source field handling
- Orchestrator and board stability around run lifecycle (e.g. `mix svarm.run` teardown, BoardLive assigns, Issue struct access in run metadata)
- Idempotent CreateTasks migration for existing databases
- Ensure secrets stay in environment / `.env` (gitignored); never commit keys

### Security

- Approvals and secrets expected from environment / production auth config; agent credentials never written into task metadata or config files checked into git

