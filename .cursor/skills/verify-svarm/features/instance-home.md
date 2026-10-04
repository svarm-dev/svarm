# Instance home

`/` is the instance overview: tracker, workflow path, agent count, board emptiness, approval mode, and a primary **Open board** action.

## Sub-features

- `home-instance` shows the This instance definition list.
- `home-open-board` navigates to `/board`.
- `home-empty-hint` tells the operator the board is empty (fresh verify launch).

## How to get to it (user POV)

- Open `http://127.0.0.1:<port>/`.
- Choose the Svärm wordmark in the header from any page.

## Driving it with svarm-verify

Preconditions:

- `svarm-verify doctor` is OK.
- Board still empty unless proving the post-seed ticket count.

- **Instance strip.** Run `svarm-verify save-html / home.html`. The HTML contains `Control for your agent loop`, `aria-label="This instance"`, `Tracker`, `Agents`, and `Approvals`. Screenshot the section with the Svärm header visible.
- **Empty hint.** On a fresh launch, Board row reads `empty` and the hint mentions seeding a zero-key demo.
- **Open board.** Choose **Open board**. The browser lands on `/board` with heading `Board`.
- **Proof.** `home.html` and a screenshot of This instance. Feature ID `instance-home`.

## Gotchas

- `/health` is plain text `ok` with no chrome. It is doctor-only, not this feature.
- After seed, the Board row shows a ticket count instead of `empty`. Capture empty and seeded as distinct proofs if both matter.
- **Configure setup** appears when setup is incomplete. Do not treat its absence as a failure if keys already live in the operator environment of a non-isolated instance — isolated launch uses a blank Settings DB so the button should show.
