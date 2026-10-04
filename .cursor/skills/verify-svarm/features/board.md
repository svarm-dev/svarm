# Team board

The board is the operator's live view of tickets: empty onboarding, Seed demo for a zero-key loop, kanban columns, card selection, streamed run console, and inline approve/reject.

## Sub-features

- `board-empty` shows first-run onboarding with no column strip.
- `board-seed` queues three mock demo tasks from the Seed demo control.
- `board-columns` shows Todo / Needs approval / In progress / Review / Done / Failed.
- `board-select` opens the run console for a card.
- `board-approve` moves the gated `demo_code` card out of Needs approval.

## How to get to it (user POV)

- Open `http://127.0.0.1:<port>/board` (or primary nav **Board**).
- Open `/` then **Open board**.
- Choose **Seed demo** on the empty onboarding panel or in the board header.
- Click a task title button, or use `j` / `k` then Escape to clear.
- On a Needs approval card, choose **Approve** or **Reject**.

## Driving it with svarm-verify

Preconditions:

- `svarm-verify doctor` is OK.
- Board is empty (fresh launch, no seed yet) for `board-empty`.
- Browser open at `$BASE_URL/board`.

- **Empty board.** Load `/board`. Run `svarm-verify save-html /board empty-board.html`. The HTML contains `All quiet. No tickets yet.` and `First-run checklist`, and does not contain `Needs approval` as a column heading. Screenshot the onboarding panel with heading `Board`.
- **Header seed control.** On the empty board, the header still has **Seed demo** (Mix demo routes). The onboarding panel also has **Seed demo**.
- **Seed demo.** Choose **Seed demo** in the browser, or run `svarm-verify seed "create a cool app"`. Flash text `Cleared board and queued` appears (browser) or HTTP 302 (helper). Wait until cards render.
- **Seeded titles.** Run `svarm-verify save-html /board seeded-board.html`. The HTML contains `Demo mode`, `Demo: clarify scope for create a cool app`, `Demo: implement core change`, and `Demo: verify and document`. Columns `data-status="todo"` and `data-status="pending_approval"` exist.
- **Select card.** Click the button whose accessible name starts with `Demo: implement core change` (`#task-<id>`). `#run-console` shows that title and task id. Screenshot the selected card ring plus console.
- **Inline approve.** On that card, choose **Approve**. The card leaves **Needs approval** (status becomes Todo or In progress). Re-dump `/board` or screenshot the Needs approval column count dropping.
- **Proof.** Keep `empty-board.html`, `seeded-board.html`, the selected-console screenshot, and doctor stdout. Feature ID `board`.

## Gotchas

- `mix svarm.demo` uses another temp DB. It will never populate this `/board`.
- Dead `GET /board` HTML can show cards before the LiveView socket connects; still wait for the Demo mode banner after seed before clicking.
- Seed **wipes** the isolated board. That is required. Never run seed against port 4000 / `~/.svarm`.
- Seed refuses a GitHub tracker or non-`demo_*` assignees. Doctor plus the verify workflow copy must stay local.
- `demo_code` is gated on purpose. Research/docs may run without Approve.
- Keyboard `j`/`k` only works when the LiveView has window focus.
- After seed, wait for LiveView stream insert; a screenshot taken immediately can still show onboarding.
