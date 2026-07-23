# Screenshots for README

The README expects three stills (PNG). Capture them after path **A** (demo) works, then optionally replace with dogfood from a real GitHub run.

## Required files

| File | Capture |
|------|---------|
| `board-seeded.png` | `/board` after Seed demo or `SVARM_SEED_DEMO=1` — columns with 3 demo tasks |
| `card-running.png` | Selected card with live log while a demo (or real) agent is running |
| `cost-receipt.png` | GitHub issue comment with cost receipt (path **B**), or board cost chip + log if no GH yet |

Optional: `demo.gif` (~20s) of seed → running → review.

## How to capture (local)

```bash
# Demo board
docker compose --profile demo up --build
# open http://localhost:4000/board — wait for motion, screenshot

# Or Mix
mix setup && mix phx.server
# POST Seed demo from the board button
```

Prefer a real dogfood receipt for `cost-receipt.png` when you have one (see vault Dogfooding). Until files exist, GitHub will show broken images — that’s intentional so the gap is obvious.

## Dimensions

~1280px wide, light theme preferred for README contrast. Crop chrome if needed; keep Svärm UI readable.
