# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Post-0.1.3 on `main` (not yet tagged): run console, optional CI resume, trust/perf hardening. Tagged release remains **v0.1.3**.

### Added

- **Review-resume detection** ([#112](https://github.com/svarm-dev/svarm/issues/112)): poll GitHub PR reviews for managed tickets in **review**; record changes-requested state and show a board chip. **No auto re-dispatch** (follow-up #113). Same poll-on-tick path as CI Checks — no webhooks.
- **Toolchain preflight contract** ([#108](https://github.com/svarm-dev/svarm/issues/108)): optional `tools` / `tools_mode` on agents (`fail` default, or `warn`); PATH-only check before spawn so missing host tools do not burn tokens; board `[toolchain: …]` note
- **Sample skill pack `ai-task`** ([#52](https://github.com/svarm-dev/svarm/issues/52), [#124](https://github.com/svarm-dev/svarm/pull/124)): in-repo reference pack at `priv/packs/ai-task` (Docker `/app/packs/ai-task`); enable with `skills` on an agent — [docs/agents.md](docs/agents.md#sample-pack-ai-task)
- **Agent skills dispatch inject** ([#107](https://github.com/svarm-dev/svarm/issues/107)): configured `skills` packs are copied into the ticket workspace (`.agents/skills/`) at run start, with a prompt note and Pi `--skill` flags; missing/invalid packs fail closed
- **Agent `skills` schema** ([#106](https://github.com/svarm-dev/svarm/issues/106)): optional path list on `agents.toml` / Settings overlay
- **CI resume + circuit breaker** ([#44](https://github.com/svarm-dev/svarm/issues/44), [#60](https://github.com/svarm-dev/svarm/pull/60)): when enabled, poll GitHub Checks for managed PRs in **review** and re-dispatch a **fresh** agent run with failure context until **N** attempts open a durable circuit; board chip **“CI retries exhausted”**; default **off** (`ci_resume` in WORKFLOW / `SVARM_CI_RESUME_*`); durable `task_coordination` (PR link, counts); GitHub `todo` strips status labels; PR owner/repo bound to tracker; resume skips re-approval after first human gate; Checks HTTP timeouts + max polls/tick
- **Run console** on the board ([#43](https://github.com/svarm-dev/svarm/issues/43), [#47](https://github.com/svarm-dev/svarm/pull/47)): dense mono console with agent/model/status/cost chrome, late-join hydrate from `RunLog`, attach deep links (`/board?task=…&attach=1`); agent lines and run markers persist once in `Events` (zero open boards still record; multiple LiveViews never double-write)
- DB indexes for usage window queries and task eligibility sort ([#70](https://github.com/svarm-dev/svarm/issues/70), [#88](https://github.com/svarm-dev/svarm/pull/88))

### Changed

- GETTING-STARTED journeys named by tracker topology, not lettered paths: **Feel the board** (local board, no tracker), **Real tracker loop** (external issue tracker — GitHub today), **Team hardening** ([#124](https://github.com/svarm-dev/svarm/pull/124))
- Issue forms: **Ready to build** + **Epic** templates; Feature request clarified as ideas-only; CONTRIBUTING documents the forms
- README Status lists post-0.1.3 capabilities on `main` (run console, optional CI resume) while **Current release** stays v0.1.3 until the next tag
- README aligned with v0.1.3 governance floor: `/setup`, `APPROVALS_*` / budget env, agent env allowlist, estimated cost label, docs links ([#42](https://github.com/svarm-dev/svarm/pull/42))
- Board card costs use SQL aggregates instead of per-card N+1 loads ([#66](https://github.com/svarm-dev/svarm/issues/66), [#93](https://github.com/svarm-dev/svarm/pull/93))
- RunLog stream chunks coalesce in a buffer and append with SQL `content || ?` instead of full-row rewrite per delta ([#67](https://github.com/svarm-dev/svarm/issues/67), [#95](https://github.com/svarm-dev/svarm/pull/95))
- Settings crypto reads `secret_key_base` from app config, not `Endpoint` ([#74](https://github.com/svarm-dev/svarm/issues/74), [#90](https://github.com/svarm-dev/svarm/pull/90))
- Board loads agents via the Board read API, not `AgentRunner` directly ([#73](https://github.com/svarm-dev/svarm/issues/73), [#84](https://github.com/svarm-dev/svarm/pull/84))
- `.env.example` no longer ships shared `svarm`/`svarm` approval defaults (demo compose still may)

### Fixed

- **Dashboard 24h/7d spend windows** use wall-clock `inserted_at` so totals survive process restarts ([#100](https://github.com/svarm-dev/svarm/issues/100))
- **Redact quoted `KEY="value"` / `KEY='value'` and bare JWTs** in agent output ([#99](https://github.com/svarm-dev/svarm/issues/99))
- **Redact.map walks lists** so MCP `content` arrays in typed `{:stream_event, ...}` payloads are scrubbed (PubSub must not carry secrets)
- **Prod fail-closed board mutations** ([#64](https://github.com/svarm-dev/svarm/issues/64), [#91](https://github.com/svarm-dev/svarm/pull/91)): approve/reject/mark-done deny when `APPROVALS_*` is unset outside local Mix `dev_routes`
- Production LiveView **origin checks** stay on (allow-list from `PHX_HOST` / `PHX_CHECK_ORIGIN`); session cookies default to **Secure** for HTTPS deploys ([#65](https://github.com/svarm-dev/svarm/issues/65), [#92](https://github.com/svarm-dev/svarm/pull/92))
- Secrets redacted in on-disk workspace `run.log` ([#63](https://github.com/svarm-dev/svarm/issues/63), [#87](https://github.com/svarm-dev/svarm/pull/87)); broader Redact patterns for common secret shapes ([#78](https://github.com/svarm-dev/svarm/issues/78), [#86](https://github.com/svarm-dev/svarm/pull/86))
- Orchestrator force-terminal status retries are non-blocking (`send_after`, no GenServer `Process.sleep`) ([#68](https://github.com/svarm-dev/svarm/issues/68), [#94](https://github.com/svarm-dev/svarm/pull/94))
- Test suite isolation: reset orchestrator env and cut fixed `Process.sleep` ([#80](https://github.com/svarm-dev/svarm/issues/80), [#96](https://github.com/svarm-dev/svarm/pull/96)); BoardLive empty-column race / Demo.seed poll leak ([#62](https://github.com/svarm-dev/svarm/issues/62), [#85](https://github.com/svarm-dev/svarm/pull/85))
- Orchestrator test isolation and pre-existing `mix ci` reach smells (frequencies, budget float coercion, flaky dispatch ticks) as part of [#47](https://github.com/svarm-dev/svarm/pull/47)

### Security

- Quoted `KEY="value"` / `KEY='value'` env dumps and bare JWTs redacted in transcripts ([#99](https://github.com/svarm-dev/svarm/issues/99))
- `Redact.map/1` walks lists (MCP tool `args` / `result` content arrays) so typed stream PubSub payloads are scrubbed
- Fail-closed board mutations without `APPROVALS_*` in production ([#64](https://github.com/svarm-dev/svarm/issues/64) / [#91](https://github.com/svarm-dev/svarm/pull/91))
- Origin allow-list + Secure session cookies in prod ([#65](https://github.com/svarm-dev/svarm/issues/65) / [#92](https://github.com/svarm-dev/svarm/pull/92))
- Redact expansions + on-disk run.log scrub ([#78](https://github.com/svarm-dev/svarm/issues/78), [#63](https://github.com/svarm-dev/svarm/issues/63))

### Dependencies

- Dev/test security toolchain: `mix_audit` + `sobelow` wired into `mix ci` (`deps.audit`, `sobelow --exit`); `lazy_html` constrained to `~> 0.1.0` ([#82](https://github.com/svarm-dev/svarm/issues/82), [#89](https://github.com/svarm-dev/svarm/pull/89))
- `mint` 1.9.1 → 1.9.3 (HTTP client advisories) ([#61](https://github.com/svarm-dev/svarm/issues/61), [#83](https://github.com/svarm-dev/svarm/pull/83))
- `phoenix_live_reload` 1.6.2 → 1.7.0 (dev) ([#39](https://github.com/svarm-dev/svarm/pull/39))

## [0.1.3] - 2026-08-02

Governance trust floor for self-hosted operators: honest docs, board mutation auth, hard spend caps, usage export, allowlisted agent env, and one-shot approval — plus Path B dogfood and demo hardening since 0.1.2.

**Breaking:** empty agent `env` no longer inherits the full host process environment. List API keys explicitly in `agents.toml` (e.g. `OPENROUTER_API_KEY = "$OPENROUTER_API_KEY"`). Default agent block was updated; custom agents need the same.

### Added

- **Governance floor** ([#30](https://github.com/svarm-dev/svarm/issues/30), [#41](https://github.com/svarm-dev/svarm/pull/41)): board approve/reject/mark-done gated by the same `APPROVALS_*` Basic Auth when configured ([#32](https://github.com/svarm-dev/svarm/issues/32)); hard daily/per-ticket USD caps block **new** spawns (`SVARM_BUDGET_*` / WORKFLOW `budget.*`) ([#34](https://github.com/svarm-dev/svarm/issues/34)); `mix svarm.export_usage` CSV/JSON ledger export ([#35](https://github.com/svarm-dev/svarm/issues/35)); one-shot sticky approval after human approve ([#37](https://github.com/svarm-dev/svarm/issues/37))
- **Setup preflight** (`/setup`): live readiness (key source, default model, form-scoped tracker probe), model suggestions after OpenRouter test, single Apply path ([#5](https://github.com/svarm-dev/svarm/pull/5))
- **Dashboard** governance spine: human-wait first, windowed spend/tokens from one summary, busy-first agent roster ([#5](https://github.com/svarm-dev/svarm/pull/5))
- GitHub issue/PR templates and Dependabot for Hex + Actions ([#6](https://github.com/svarm-dev/svarm/pull/6))
- Human-readable agent **tool logs** on the board (unwrap pi/MCP content blocks; no raw Elixir map dumps) ([#23](https://github.com/svarm-dev/svarm/pull/23), [#28](https://github.com/svarm-dev/svarm/issues/28))
- WORKFLOW placeholder `{{issue.source_id}}` for tracker-native issue numbers (e.g. GitHub `#26`) ([#23](https://github.com/svarm-dev/svarm/pull/23))
- Docker: default git author for agent commits (`SVARM_GIT_EMAIL` / `SVARM_GIT_NAME`); `procps` for process cleanup ([#23](https://github.com/svarm-dev/svarm/pull/23))

### Changed

- Approximate costs (rate-table / incomplete rows) are labeled **estimated** everywhere; provider-reported USD stays exact ([#33](https://github.com/svarm-dev/svarm/issues/33))
- Empty agent `env` uses allowlist Port env only (no full host inheritance); list API keys in `agents.toml` ([#36](https://github.com/svarm-dev/svarm/issues/36))
- License: **FSL-1.1-MIT** (Fair Source / source available → MIT after 2 years per version); was MIT
- Successful agent runs that leave the tracker in an active status move to **review** once (no endless re-dispatch) ([#23](https://github.com/svarm-dev/svarm/pull/23))
- Run cost prefers **provider-reported USD** when present, then the rate table ([#23](https://github.com/svarm-dev/svarm/pull/23))

### Fixed

- Public docs no longer claim OS sandbox or hard budgets before they ship; path-isolation wording ([#31](https://github.com/svarm-dev/svarm/issues/31))
- Board card cost no longer shows a stray `#` before the dollar amount
- Docker/demo seed forces approval overlay: research + docs trusted, **code** gated (even if host WORKFLOW still trusts all demo agents)
- Demo approval: **code** gated (`demo_code` untrusted); research + docs trusted; approve allowed on demo tasks
- Seed demo clears the board before re-seeding; review cards get **Mark done** on local board (no PR required)
- `SVARM_SEED_DEMO` no longer enables the Seed demo UI — needs `SVARM_DEMO_ROUTES` (or Mix `dev_routes`)
- Docker demo seed keeps `demo_*` assignees (Dispatch no longer overwrites them with ProfileRouter → Pi/OpenRouter)
- Dashboard session token totals with negative monotonic timestamps; completed runs without assignee count on the right agent
- Approve/reject gates use the active tracker (Local or GitHub), not a Local-only path ([#19](https://github.com/svarm-dev/svarm/pull/19))
- GitHub board no longer fills **Todo** with pull requests and unlabeled closed issues ([#23](https://github.com/svarm-dev/svarm/pull/23))
- Docker pi runs no longer crash after exit when `pgrep` is missing, and no longer restart the orchestrator on worker DOWN ([#23](https://github.com/svarm-dev/svarm/pull/23))
- GitHub API 403s log the real message and rate-limit headers (not always “rate limited”) ([#23](https://github.com/svarm-dev/svarm/pull/23))
- Usage ledger stores provider cost so OpenRouter spend can show on receipts ([#23](https://github.com/svarm-dev/svarm/pull/23))

### Security

- Board high-trust mutations require the same Basic Auth as `/approvals` when `APPROVALS_*` is set ([#32](https://github.com/svarm-dev/svarm/issues/32))
- Agent child processes no longer inherit the full host environment by default ([#36](https://github.com/svarm-dev/svarm/issues/36))
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

[Unreleased]: https://github.com/svarm-dev/svarm/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/svarm-dev/svarm/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/svarm-dev/svarm/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/svarm-dev/svarm/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/svarm-dev/svarm/releases/tag/v0.1.0
