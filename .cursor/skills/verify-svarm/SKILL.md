---
name: verify-svarm
description: Drive the Svärm Phoenix board the way an operator does — isolated Mix server, LiveView clicks, HTTP checks. Use when proving board, dashboard, home, approvals, or setup UI behavior.
---

# Verify Svärm

Scripted operator path for the **Svärm** control-plane UI (Phoenix LiveView). Primary surface is `/board`. Also: `/dashboard`, `/`, `/approvals`, `/setup`. Mix CLI (`mix svarm.demo`) is a **separate** BEAM + temp DB — it does not drive `/board`.

This skill is for agents. Read `features/README.md`, then the matching feature file.

## Launch

Never attach to an operator `mix phx.server` on port **4000** or to `~/.svarm/kanban/kanban.db`. Two Mix instances can run side by side only when **port and SQLite file both differ**. If doctor would fail, stop; do not seed the shared board.

From the repo root:

```bash
.cursor/skills/verify-svarm/bin/svarm-verify launch
.cursor/skills/verify-svarm/bin/svarm-verify doctor
```

Ready when `GET /health` returns `ok` and doctor prints `OK`. Default listen URL is `http://127.0.0.1:4100` (scans 4100–4140, **skips 4000**).

What launch actually does:

- `setsid mix phx.server` with `MIX_ENV=dev`
- `PORT` = chosen verify port
- `SVARM_DB_PATH` = `.cursor/skills/verify-svarm/.run/data/kanban.db`
- `SVARM_WORKFLOW_PATH` = a copy of `priv/workflow_template.md` whose `workspace.root` is the verify data dir (not `~/svarm_workspaces`)
- unsets `APPROVALS_USER`, `APPROVALS_PASSWORD`, `BOARD_READ_AUTH`, `SVARM_SEED_DEMO` so Mix stays open and the board starts empty
- `SVARM_DEMO_ROUTES=1` (Mix `dev_routes` already enables Seed demo)

State file: `.cursor/skills/verify-svarm/.run/instance.env` (`PID`, `PORT`, `BASE_URL`, `DB_PATH`).

Teardown:

```bash
.cursor/skills/verify-svarm/bin/svarm-verify cleanup
```

Kills the process group of the PID we started. Does **not** delete proof under `artifacts/`.

## Doctor

Run first whenever anything looks off:

```bash
.cursor/skills/verify-svarm/bin/svarm-verify doctor
```

Pass means: state file exists, PID alive, port is not 4000, DB path is not `~/.svarm/kanban/kanban.db`, `/health` is `ok`, `/board` HTML contains the `Board` heading and is not the load-error page, `/` contains `This instance`.

If doctor fails, cleanup (if we launched) and relaunch. Do not click **Seed demo** on someone else's instance.

## Drive

**Harness:** `svarm-verify` for HTTP (health, dead HTML, CSRF seed). A real browser (Cursor computer-use / CDP) for LiveView clicks — Phoenix LiveView is a websocket; curl cannot `phx-click`.

Stable handles (prefer these over coordinates):

| Handle | Kind |
|--------|------|
| `/board`, `/dashboard`, `/`, `/approvals`, `/setup`, `/health` | routes |
| Primary nav `Board`, `Dashboard`, `Setup`, `Approvals` | `aria-label="Primary"` |
| `Seed demo` | button / POST link (empty board **and** header when `demo_routes`) |
| `Refresh` | button on board and dashboard |
| Column `data-status` = `todo` \| `pending_approval` \| `in_progress` \| `review` \| `done` \| `failed` | headings Todo, Needs approval, In progress, Review, Done, Failed |
| Task card | `button#task-<id>` (title text inside) |
| Run console | `#run-console` |
| `Approve` / `Reject` | card buttons when wait-reason is approval |
| `Mark done` | console button on `review` cards |
| Dashboard spend windows | `aria-label="Spend time window"` buttons `Session`, `24h`, `7d` |
| Dashboard ROI | `[data-testid="roi-card"]` |
| Setup form | `#setup-form`, `#setup-provider-id`, `#setup-tracker-kind` |
| Approvals | `h1` Approvals; forms `#approval-approve-<id>` |

HTTP helpers:

```bash
.cursor/skills/verify-svarm/bin/svarm-verify get /health
.cursor/skills/verify-svarm/bin/svarm-verify seed "create a cool app"
.cursor/skills/verify-svarm/bin/svarm-verify save-html /board board-after-seed.html
```

`seed` POSTs `/dev/demo/seed` with the `/board` CSRF cookie. Expect **302** to `/board`. That is the same control as the **Seed demo** button.

Browser: open `$BASE_URL/board` from `instance.env`. After seed, wait until cards exist (Demo mode banner + titles below) — LiveView hydrates; a single screenshot of the spinner is not proof.

Seeded mock titles (goal `create a cool app`):

- `Demo: clarify scope for create a cool app` (`demo_research`)
- `Demo: implement core change` (`demo_code` — gated, **Needs approval**)
- `Demo: verify and document` (`demo_docs`)

## Evidence

Directory: `.cursor/skills/verify-svarm/artifacts/` (gitignored). Cleanup must leave this tree. On Cursor Cloud, also copy the proof set to `/opt/cursor/artifacts/`.

Proof standards:

- Exercise the operator path (nav, Seed demo, card select, Approve). Do not call `KanbanBridge` / `Approval` from IEx as a substitute for the UI, except as a **second** read of side effects after the UI action.
- Capture the action and the resulting state (empty board **then** seeded board; card **then** `#run-console` with that task id).
- Side effects: after seed, `save-html /board` contains the three Demo titles; after Approve, the code card leaves **Needs approval** (or the Approvals page no longer lists it). SQLite at `DB_PATH` is the same instance doctor reported.
- Mocks: Seed demo uses mock decompose + `demo_*` agents by design. That **is** the product zero-key path. Do not treat it as a fake proof of GitHub dispatch.
- `mix svarm.demo` is not proof of `/board`. `mix test` is not this skill (keep running tests; they do not replace a driven instance).

Minimum artifact set for a board proof:

1. HTML dump of empty `/board` (onboarding `All quiet. No tickets yet.`)
2. HTML dump (and screenshot) after seed showing Demo titles + `Demo mode`
3. Screenshot of a selected card with `#run-console` showing the task id/title
4. `svarm-verify doctor` stdout

## Cleanup

```bash
.cursor/skills/verify-svarm/bin/svarm-verify cleanup
```

Stops only the PID/process group recorded in `.run/instance.env`. Removes `.run/data` (DB + workflow copy). **Keeps** `artifacts/`. Never `pkill -f mix` / `pkill -f phx`.

## Helpers

```bash
.cursor/skills/verify-svarm/bin/svarm-verify launch
.cursor/skills/verify-svarm/bin/svarm-verify doctor
.cursor/skills/verify-svarm/bin/svarm-verify seed
.cursor/skills/verify-svarm/bin/svarm-verify get /board
.cursor/skills/verify-svarm/bin/svarm-verify save-html /board board.html
.cursor/skills/verify-svarm/bin/svarm-verify cleanup
```

The script is executable. Read it if a flag is unclear; do not reverse-engineer Mix from scratch.

## Feature map

Index: [`features/README.md`](features/README.md). Drive every listed entry point for the feature under test; skipping one is not “verified via another path.”
