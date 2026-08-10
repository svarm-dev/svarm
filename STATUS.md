# STATUS — coding-agent progress

> Lightweight snapshot for **coding agents** and maintainers working this repo.  
> **Not** the product roadmap. Priority of *what to build next* lives in open GitHub issues (and maintainer notes outside this file).  
> **Not** a chat log. Keep updates rare and boring.

## Noise rules (important)

1. **Update `STATUS.md` only inside a real work PR** (same PR as code/docs that already needed to land).
2. **Never** open a STATUS-only PR or commit.
3. Touch at most: **Snapshot** fields that changed + **one** Session log line.
4. Session log: **newest first, max 5 lines** — drop older entries when adding.
5. No secrets, no private paths, no strategy essays.

If nothing material changed on `main` or your PR, **do not** edit this file.

---

## Snapshot

| Field | Value |
|-------|--------|
| **Updated** | 2026-08-10 |
| **`main`** | `34e518e` — perf(board): reduce LiveView load (#104) |
| **Latest tag** | **v0.1.3** (2026-08-02) — governance floor |
| **Unreleased on main** | Run console (#43/#47), CI resume+circuit (#44/#60, default off), trust/perf (#83–#96, #102–#104) |
| **Open PRs** | [#101](https://github.com/svarm-dev/svarm/pull/101) docs · [#105](https://github.com/svarm-dev/svarm/pull/105) this progress-bus doc |
| **Focus (code)** | **[#48](https://github.com/svarm-dev/svarm/issues/48)** thin toolchain preflight + shared agent skills schema |
| **Next (code)** | [#49](https://github.com/svarm-dev/svarm/issues/49) typed stream · [#50](https://github.com/svarm-dev/svarm/issues/50) review-changes resume |
| **Parallel (small)** | Soft budget hold [#45](https://github.com/svarm-dev/svarm/issues/45) · hygiene [#97](https://github.com/svarm-dev/svarm/issues/97)–[#100](https://github.com/svarm-dev/svarm/issues/100) |

Do **not** invent a parallel priority list here. When in doubt: `gh issue list --state open` and the issue you were assigned.

---

## Blocked (human / external)

_None known._  
Format when needed: `YYYY-MM-DD · one sentence · issue/PR link`

---

## Session log (newest first, max 5)

- 2026-08-10 · docs: quieter STATUS rules + public-safe wording (#105)
- 2026-08-10 · main · #104 board streams · #103 runner tests · #102 auth TTL

---

## Suggested claim order (mirrors open product issues)

| Order | Issue | Title |
|-------|-------|--------|
| 1 | [#48](https://github.com/svarm-dev/svarm/issues/48) | Thin toolchain preflight + shared agent skills |
| 2 | [#49](https://github.com/svarm-dev/svarm/issues/49) | Typed stream events in the run console |
| 3 | [#50](https://github.com/svarm-dev/svarm/issues/50) | Resume when reviewers request changes |

Full list always wins over this table if they disagree: `gh issue list --state open`.

---

## Protocol

1. **Code work = GitHub issue** — not a side conversation only.
2. **One issue → one branch → one PR** with `Closes #N`. Humans merge.
3. **PR body:** optional `## For maintainer` only for product/positioning questions; delete if unused.
4. **STATUS:** update only in that same PR when Snapshot/Focus actually changed.
5. Maintainer-only non-code notes stay **out of this file**.
