# Setup

`/setup` is the in-app preflight form: advertised LLM provider, tracker, and default model. Secrets stay in the instance DB when saved. Verification drives **visibility and chrome**, not a live key save.

## Sub-features

- `setup-open` renders the Setup heading and `#setup-form`.
- `setup-provider` shows provider select `#setup-provider-id` and an API key field.
- `setup-tracker` shows tracker select `#setup-tracker-kind`.
- `setup-no-save` leaves the form without submitting secrets.

## How to get to it (user POV)

- Open `/setup`.
- Choose **Setup** in the primary nav.
- From an empty board, choose **Open setup** / **Configure in /setup**.

## Driving it with svarm-verify

Preconditions:

- `svarm-verify doctor` is OK.
- Approvals pipeline is open (Mix verify unsets `APPROVALS_*`).

- **Open setup.** Browser or `svarm-verify save-html /setup setup.html`. Heading `Setup`, form `#setup-form`, and copy about connecting a provider and tracker are present. Screenshot the form with primary nav **Setup** current.
- **Provider chrome.** `#setup-provider-id` exists. Button named like `Test OpenRouter` (label follows the selected provider) is visible. Do **not** paste real keys into evidence.
- **Tracker chrome.** `#setup-tracker-kind` exists.
- **Leave unsaved.** Navigate to **Board** without **Apply**. `/setup` reload still shows the empty/unsaved form (no new encrypted key required for this proof).
- **Proof.** `setup.html` plus a screenshot of `#setup-form`. Feature ID `setup`.

## Gotchas

- Do not submit `save_and_apply` with a real API key during a recorded proof. That writes secrets into the verify SQLite file and can leak into artifacts.
- **Test OpenRouter** without a key is allowed to fail; a failed test status is not a product regression for this skill.
- `/setup` uses the approvals plug. 401 means Basic Auth leaked into Mix; stop and relaunch via `svarm-verify launch`.
- File/env provider config can still work when Settings is empty. An empty form on a verify DB is expected, not "setup broken."
