# Screenshots for README

Captured from a running local board (Playwright, light theme, 1440×900).

| File | Content |
|------|---------|
| `board-seeded.png` | `/board` with demo cards, current nav (Dashboard / Board / Setup / Approvals), session cost, **Changes requested** chip |
| `card-running.png` | Selected review card + typed **run console** (narrative log, cost, detection-only copy) |
| `dashboard.png` | Waiting on humans, Spend card (Session / 24h / 7d), roster, task distribution, recent runs |

A real GitHub bot cost-comment still is preferred for marketing when dogfooding (the real tracker loop). Until then, `dashboard.png` is the in-app cost surface.

## Recapture

```bash
mix phx.server   # or docker compose --profile demo up
# browser or Playwright at 1440×900, light theme
```
