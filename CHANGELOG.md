# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Review Station** ([#155](https://github.com/svarm-dev/svarm/issues/155), [#156](https://github.com/svarm-dev/svarm/issues/156), epic [#152](https://github.com/svarm-dev/svarm/issues/152)): structured **Evidence** on selected review cards (PR, attempts, agent/model, cost, age) plus PR/no-PR glance chips; GitHub always polls Checks for a `pass` / `fail` / `pending` / `unknown` summary chip (N/A on the local tracker). Informational only — humans still merge on GitHub.
- **Dashboard Outcomes ROI** ([#158](https://github.com/svarm-dev/svarm/issues/158)): `/dashboard` strip with merge rate and `$/merged` over the Spend window (session/24h/7d), overall + per agent; estimated spend labeled. Empty when no ledger rows in the window.
- **Usage outcome buckets** ([#157](https://github.com/svarm-dev/svarm/issues/157), [#168](https://github.com/svarm-dev/svarm/pull/168)): `Usage.by_outcome/1` groups spend as `:merged`, `:in_review`, or `:other` at query time (append-only ledger). GitHub: `:merged` when coordination recorded a PR and the API reports `merged: true`, even if the ticket is still `review`. Local / no-PR stay status-based (`done` = success). Closed-unmerged PRs and API errors do not invent merges. Estimated spend is flagged.
- **Git worktree isolation** ([#159](https://github.com/svarm-dev/svarm/issues/159)): optional WORKFLOW `workspace.isolation: worktree` (default `path`) plus `workspace.git_repo`; each ticket gets a `git worktree` under `workspace.root`. Still directory-level isolation, not a container — see SECURITY.md / GETTING-STARTED.
- **Steer live PiRPC runs** ([#150](https://github.com/svarm-dev/svarm/issues/150), epic [#53](https://github.com/svarm-dev/svarm/issues/53)): run console **Steer** queues pi RPC `type: steer` on a live session (same `board_auth_at` as approve/answer). CLI disabled; hidden while a mid-run question is parked. Mailbox steers that race a park are not written during the wait. Follow-up-after-settle is not in this slice.
- **Dashboard per-agent 24h cost + retry share** ([#54](https://github.com/svarm-dev/svarm/issues/54)): roster shows wall-clock 24h spend from the usage ledger (estimated rows labeled `est.`) and retry `retried/total` when any assigned task has `attempts > 0`, else **n/a**.
- **Soft budget hold** ([#45](https://github.com/svarm-dev/svarm/issues/45)): WORKFLOW `budget.mode` / `SVARM_BUDGET_MODE` = `hard` (default, skip spawn) or `hold` (park ticket as **Over budget** until a one-shot board **Approve overage**, or until the cap is raised). Estimated usage still counts toward the cap.

### Changed

- **Tracker resolve single path** ([#169](https://github.com/svarm-dev/svarm/pull/169)): kind → adapter mapping lives only in `Svarm.Tracker.Resolve`; Orchestrator uses adapter capabilities instead of `== Tracker.Local` branches. Mix `svarm.demo` pins the local tracker so a GitHub WORKFLOW/Settings overlay cannot pull the isolated demo off its temp board.

### Fixed

- **GitHub `pending_approval` labels** ([#173](https://github.com/svarm-dev/svarm/issues/173)): default maps persist `pending_approval` as `status: pending-approval` so gated tickets leave Todo and show in **Needs approval** / `/approvals`. Budget hold reuses that status plus `wait_reason` (no extra label). WORKFLOW `tracker.status_labels` / `reverse_labels` are parsed; invalid maps fail closed.
- **Review-resume fallback cap** ([#191](https://github.com/svarm-dev/svarm/issues/191)): empty review-column id list falls back to `Coordination.list_with_pr(..., limit: 50)` — same cap as the labeled path. A tagged `list_issues` error skips that fallback instead of scanning every PR row.
- **GitHub `list_issues` errors** ([#176](https://github.com/svarm-dev/svarm/issues/176), [#201](https://github.com/svarm-dev/svarm/pull/201)): non-200 no longer returns `{:ok, []}` (a fake empty board). `/board`, `/dashboard`, and `/` show **Cannot load GitHub issues**. Unhandled HTTP (429/400/422) and unexpected Req shapes fail closed.
- **Transient tracker errors keep in-flight work** ([#198](https://github.com/svarm-dev/svarm/pull/198)): reconcile releases a worker only on documented gone (`:not_found`) or a terminal tracker status; network / 5xx / rate-limit leave the run running for the next tick.
- **SQLite `busy_timeout`** ([#189](https://github.com/svarm-dev/svarm/issues/189), [#193](https://github.com/svarm-dev/svarm/pull/193)): concurrent RunLog / usage / kanban writers wait up to 5s on `SQLITE_BUSY` instead of failing immediately.
- **Orchestrator spawn error** ([#187](https://github.com/svarm-dev/svarm/issues/187)): `Task.Supervisor.start_child` `{:error, reason}` is logged and the poll loop continues instead of crashing the GenServer (in-memory claims/retries survive). One-shot approval and overage permits are kept so the ticket stays eligible on a later tick.
- **GitHub run comments omit board/run-log URLs** ([#181](https://github.com/svarm-dev/svarm/issues/181)): `SVARM_BASE_URL` no longer puts `/board?task=…&attach=1` in issue comments unless `SVARM_COMMENT_CONSOLE_LINKS=true`. Default Compose / prod stay off. Cost / harness / session rows are unchanged. Board reads remain unauthenticated.
- **WORKFLOW `workspace.isolation` fail closed** ([#160](https://github.com/svarm-dev/svarm/issues/160), [#167](https://github.com/svarm-dev/svarm/pull/167), [#170](https://github.com/svarm-dev/svarm/pull/170)): unknown values (`container`, typos) return `{:error, :invalid_workspace_isolation}` from `validate_workflow/1` instead of silently becoming `path`. Default remains **`path`**. Retry / resume spawn also honor preflight (they previously skipped it), and `Workspace.ensure/3` rejects unknown modes instead of coercing to `path`. GETTING-STARTED names `workspace.isolation` / `workspace.git_repo` and adds a path vs worktree vs container=later honesty row.
- **Worktree teardown + git timeout** ([#162](https://github.com/svarm-dev/svarm/issues/162)): `Workspace.cleanup/3` runs `git worktree remove` (force if dirty); add/list/remove share a bounded Port helper (default 30s → `{:error, :git_timeout}` with best-effort leftover cleanup so the next ensure is not stuck).
- **Board / dashboard first paint** ([#163](https://github.com/svarm-dev/svarm/issues/163)): dead GET `/board` and `/dashboard` render real cards instead of a skeleton, so the stock LiveView "Attempting to reconnect" banner no longer flashes on every visit. `instance_status/1` can reuse already-loaded agents/task count.
- **Budget hold unlocks**: trust `/approvals` Approve on an over-budget ticket now grants the overage permit; Reject clears the hold; raising the cap no longer resurrects rejected cards; overage permit is recorded before `todo` so a concurrent tick cannot re-park.

## [0.1.5] - 2026-08-14

Mid-run Q&A & review-resume spawn. Optional review re-dispatch (default **off**). Compact run console. No breaking env change.

### Added

- **Mid-run Q&A board chip + answer UI** ([#116](https://github.com/svarm-dev/svarm/issues/116)): **Waiting for answer** chip on running cards; selected-task confirm/select/input form; same `board_auth_at` gate as approve/reject. Operator notes in GETTING-STARTED. Completes epic #51.
- **Mid-run Q&A answer API + PiRPC inject** ([#115](https://github.com/svarm-dev/svarm/issues/115)): `Svarm.AgentQuestion` parks PiRPC `extension_ui_request` dialogs, injects `extension_ui_response`, and persists wait on kanban + `task_coordination` (GitHub cards). Deadline (default 15 min) or cancel continues the run; CLI inject is unsupported. Board answer UI is #116.
- **Mid-run Q&A wait fields** ([#114](https://github.com/svarm-dev/svarm/issues/114)): durable `wait_reason` + `pending_question` on the kanban task (SQLite); `KanbanBridge.put_pending_question/2` / `clear_pending_question/1`; `Board.wait_reason/1` returns `:agent_question` on `in_progress` when a question is pending. No answer UI yet (#115–#116).
- **Review-resume re-dispatch** ([#113](https://github.com/svarm-dev/svarm/issues/113)): when enabled, the first GitHub changes-requested transition re-opens the ticket for a fresh agent run with review context; later SHA refreshes in the same episode stay detect-only. Shares `ci_resume_count` / `ci_circuit_open` and the CI resume `max_attempts` cap. Default **off** (`review_resume.enabled` / `SVARM_REVIEW_RESUME_ENABLED`). Detection stays always-on for GitHub.

### Changed

- README Status is **Current release: v0.1.5**; mid-run Q&A moved out of **Not shipped** ([#142](https://github.com/svarm-dev/svarm/issues/142))

### Fixed

- **AgentQuestion answer/cancel double-inject**: `answer/2` and `cancel/1` clear durable wait immediately after inject so the board form cannot submit twice into the same PiRPC run (or a later dialog); optional `request_id` must match when present
- **AgentQuestion clear/cancel/invalid park**: `clear/1` no longer PubSubs `status: in_progress` (would yank a review/failed card back); `cancel/1` returns `{:error, :invalid}` instead of raising when `request_id` is missing; invalid dialog park fails the PiRPC run instead of stalling until wall-clock timeout
- **Compact terminal run console** ([#130](https://github.com/svarm-dev/svarm/issues/130)): collapse repeated projection whitespace and render typed output as dense terminal rows instead of separate padded cards

## [0.1.4] - 2026-08-14

Run console & CI resume. Optional CI-fail re-dispatch (default **off**). Review-resume is **detect-only** — no auto spawn (#113). No breaking env-inheritance change (that was 0.1.3).

### Added

- **Typed stream run console** ([#110](https://github.com/svarm-dev/svarm/issues/110), [#111](https://github.com/svarm-dev/svarm/issues/111)): live path broadcasts v1 narrative, tool, and run events; BoardLive renders distinct chrome without duplicate compatibility lines; RunLog keeps a text projection and rehydrates compatible chrome on late join/re-selection (no schema change)
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
- README Status is **Current release: v0.1.4**; screenshots recaptured for current nav, run console, and dashboard spend chips ([#135](https://github.com/svarm-dev/svarm/issues/135), [#136](https://github.com/svarm-dev/svarm/issues/136))
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

[Unreleased]: https://github.com/svarm-dev/svarm/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/svarm-dev/svarm/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/svarm-dev/svarm/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/svarm-dev/svarm/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/svarm-dev/svarm/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/svarm-dev/svarm/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/svarm-dev/svarm/releases/tag/v0.1.0
