# Dashboard

The dashboard is a read-only ops overview: work waiting on humans, spend, ROI, agent roster, and queue distribution. Task detail stays on `/board`.

## Sub-features

- `dash-open` renders the Dashboard heading and system status.
- `dash-spend` shows Spend with Session / 24h / 7d windows.
- `dash-roi` shows the ROI card.
- `dash-refresh` reloads the snapshot from the Refresh button.

## How to get to it (user POV)

- Open `/dashboard`.
- Choose **Dashboard** in the primary nav from any chrome page.
- Choose **Refresh** on the dashboard.

## Driving it with svarm-verify

Preconditions:

- `svarm-verify doctor` is OK.
- Optional: seed the board first if you need non-zero spend/queue (see board.md). Empty dashboard is a valid proof of chrome.

- **Open dashboard.** Browser or `svarm-verify save-html /dashboard dashboard.html`. Heading `Dashboard` and copy `Work waiting on humans` are present. Primary nav **Dashboard** has `aria-current="page"`.
- **Spend windows.** Find `role="group"` named `Spend time window`. Choose **24h**, then **7d**, then **Session**. Caption under Spend changes (`Wall-clock last 24 hours` vs `All ledger rows in this database`). Screenshot Spend with the pressed window.
- **ROI.** `[data-testid="roi-card"]` is in the HTML. Screenshot it with the Dashboard heading visible.
- **Refresh.** Choose **Refresh**. The page stays on `/dashboard` (no error card `Failed to load dashboard`).
- **Proof.** `dashboard.html` plus a screenshot showing heading, Spend, and ROI. Feature ID `dashboard`.

## Gotchas

- With `BOARD_READ_AUTH` the dashboard 401s. Verify launch unsets that flag; if it is set, this instance is not the isolated Mix default.
- Spend can be `$0.0` on a fresh DB. That is success, not a missing card.
- PubSub reloads coalesce (~750ms). Do not assert roster mid-tick; wait for the heading and cards.
- LiveDashboard at `/dev/dashboard` is Phoenix's metrics UI, not this page. Do not use it as proof of `/dashboard`.
