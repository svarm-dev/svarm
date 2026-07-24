# Screenshots for README

Captured from a running local board (Playwright, light theme).

| File | Content |
|------|---------|
| `board-seeded.png` | `/board` with tasks and estimated per-ticket cost |
| `card-running.png` | Selected card + run panel cost breakdown |
| `dashboard.png` | Agent roster, cost strip, task distribution, recent runs |

A real GitHub bot cost-comment still is preferred for marketing when dogfooding (path B). Until then, `dashboard.png` is the in-app cost surface.

## Recapture

```bash
mix phx.server   # or docker compose --profile demo up
# browser or Playwright at 1440×900, light theme
```
