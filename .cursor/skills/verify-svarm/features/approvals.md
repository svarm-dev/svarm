# Approvals

The approvals page lists dispatch gates. Day-to-day approve/reject also lives on the board; this page is the bulk list with the same Approve/Reject actions.

## Sub-features

- `approvals-empty` shows Nothing waiting for approval on a fresh empty board.
- `approvals-pending` lists the gated demo_code ticket after Seed demo.
- `approvals-approve` approves from this page and sends the operator back toward the board.

## How to get to it (user POV)

- Open `/approvals`.
- Choose **Approvals** in the primary nav.
- From `/board`, choose the header **Approvals** link.

## Driving it with svarm-verify

Preconditions:

- `svarm-verify doctor` is OK.
- Mix verify launch left approvals **unauthenticated** (no `APPROVALS_*`).
- For pending/approve: run `svarm-verify seed` first (or Seed demo on the board).

- **Empty list.** Before seed, `svarm-verify save-html /approvals approvals-empty.html`. Heading `Approvals` and `Nothing waiting for approval` are present. Screenshot it.
- **Pending after seed.** Seed, then save `/approvals`. The list includes `Demo: implement core change` and buttons **Approve** / **Reject** (`#approval-approve-<id>`).
- **Approve.** In the browser, submit **Approve** for that row. Land on the follow-up page without 401. Re-open `/approvals` or `/board`: that title is no longer waiting for approval.
- **Proof.** Empty HTML, pending HTML or screenshot, and a post-approve screenshot. Feature ID `approvals`.

## Gotchas

- Docker/prod Basic Auth (`svarm`/`svarm` on the demo compose profile only) is **not** the Mix verify default. A 401 means this is not the isolated launch (or `.env` leaked into Mix). Do not type operator passwords into a shared screenshot.
- Rejecting is a different sub-feature; do not call Approve proven if you only Rejected.
- Research/docs demo assignees are trusted and may never appear here.
- Board inline **Approve** is `board-approve`. This file is the `/approvals` entry point; both must be driven to claim both.
