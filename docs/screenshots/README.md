# Screenshots for README

Captured from a running local board (Playwright, light theme).

| File | Content |
|------|---------|
| `board-seeded.png` | `/board` with tasks and estimated per-ticket cost |
| `card-running.png` | Selected card + run panel cost breakdown |
| `cost-receipt.png` | `/dashboard` cost strip + recent runs (UI cost surface) |
| `dashboard.png` | Agent roster, task distribution, recent runs |

Prefer a real GitHub bot cost comment for `cost-receipt.png` when dogfooding (path B). Until then the dashboard shot documents in-app cost.

## Recapture

```bash
mix phx.server   # or docker compose --profile demo up
# then agent + Playwright MCP, or open browser at 1440×900 light theme
```
