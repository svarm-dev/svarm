# Svärm verification map

This directory is the maintained source for verifying operator-facing Svärm UI. Read this index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- Launch with `.cursor/skills/verify-svarm/bin/svarm-verify launch` (isolated `PORT` + `SVARM_DB_PATH`, not `:4000`, not `~/.svarm/kanban/kanban.db`).
- Run `svarm-verify doctor` and require `OK` plus the printed `url=` / `db=`.
- Mix `dev_routes` (or `SVARM_DEMO_ROUTES=1`): **Seed demo** is visible; `/approvals` and `/setup` are open without Basic Auth.
- Tracker is **local** (verify workflow copy of `priv/workflow_template.md`).
- Board starts **empty** unless a feature says otherwise.
- Never drive an instance this run did not launch.

## Driving conventions

- Start every recipe from the baseline unless its preconditions say otherwise.
- Prefer routes, accessible names, `data-status`, and `#task-<id>` over CSS position.
- Treat helper commands as literal.
- HTTP: `svarm-verify get` / `save-html` / `seed`.
- LiveView clicks: a real browser against `BASE_URL` from `.run/instance.env`.
- Restore isolation with `svarm-verify cleanup` after the run. Do not remove proof artifacts.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- UI proof includes HTML (dead render) and a screenshot with the Svärm nav and page heading visible.
- Mutation proof includes a second view (reload, other route, or HTML dump) of the stored result.
- Record the feature ID and entry point with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features`
2. `How to get to it (user POV)`
3. `Driving it with svarm-verify`
4. `Gotchas`

## Features

- [Team board](./board.md) — empty onboarding, Seed demo, columns, card select, run console, inline approve.
- [Dashboard](./dashboard.md) — ops overview, spend window, ROI card, nav from board.
- [Instance home](./instance-home.md) — `/` instance summary and Open board.
- [Approvals](./approvals.md) — empty list, pending demo_code, Approve/Reject.
- [Setup](./setup.md) — `/setup` form chrome without saving secrets.
