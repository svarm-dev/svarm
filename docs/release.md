# Release runbook — first public cut

**T8.** Code can be ready while the repo stays private. This is the packaging path for a cold visitor on GitHub.

Vault SoT for launch gates: `Projects/Svärm/Ops.md` (Launch checklist). Keep secrets out of git and out of that note.

| Fact | Value |
|------|--------|
| Product repo | `svarm-dev/svarm` |
| Git remote (push tags/releases) | **`github`** → `https://github.com/svarm-dev/svarm.git` (`origin` is the Forge mirror) |
| Visibility today | **private** until step 4 (confirm with `gh repo view svarm-dev/svarm --json visibility`) |
| `mix.exs` / app version | `0.1.1` after the release commit |
| Git tags / GitHub releases | **none until step 3** |
| CHANGELOG | `[0.1.0]` private first cut; `[0.1.1]` first public try path |

## Version choice

**First public tag: `v0.1.1`.**

- `[0.1.0]` already documents the private first cut — leave it.
- First-time UX + onboarding land as **0.1.1** under a dated section.
- Bump `mix.exs` `version:` to `"0.1.1"` on the release commit only.

Do **not** retcon everything into a new `0.1.0` tag unless you rewrite CHANGELOG history on purpose.

---

## 0. Preconditions (can do anytime)

- [ ] OpenRouter key **rotated** after historical leak (vault Ops — never put the key in git)
- [ ] Working tree for the release is on **`main`**, clean, tracking `github/main`
- [ ] This branch (or equivalent) merged: first-time UX T1–T3, T5–T7, T9–T13
- [ ] **T4** screenshots committed under `docs/screenshots/`:
  - `board-seeded.png`
  - `card-running.png`
  - `dashboard.png` (in-app cost surface; dogfood GitHub cost-receipt still preferred when available)
  - capture notes: [screenshots/README.md](screenshots/README.md)

---

## 1. Quality gates

From repo root (mise/shell where `mix` works):

```bash
mix precommit    # compile --warnings-as-errors, format, full tests
mix ci           # + credo --strict, dialyzer, etc. — preferred for a public tag
```

Manual smoke (do not skip for a public try path):

```bash
cp -n .env.example .env
# SECRET_KEY_BASE=$(openssl rand -base64 48)  # if still CHANGEME

docker compose --profile demo down -v 2>/dev/null || true
docker compose --profile demo up --build
# → http://localhost:4000/health   must be "ok"
# → http://localhost:4000/board    demo tasks moving
# → http://localhost:4000/         instance status filled in
```

- [ ] `mix precommit` green  
- [ ] `mix ci` green (or consciously deferred with reason)  
- [ ] Demo profile smoke passed  
- [ ] README paths A/B/C still true; Status section still honest  

---

## 2. Cut the release commit (on `main`)

Promote changelog + version in **one** commit:

1. Move `[Unreleased]` bullets into:

   ```markdown
   ## [0.1.1] - YYYY-MM-DD

   First **public** try path: Docker demo profile, approvals env, journey docs, instance home, `/health`.

   ### Added
   …(paste from Unreleased)…

   ### Changed
   …
   ```

2. Leave an empty:

   ```markdown
   ## [Unreleased]

   ```

3. Set `mix.exs` → `version: "0.1.1"`.

4. Commit, e.g. `chore: release v0.1.1`.

5. Push **`github`**:

   ```bash
   git push github main
   ```

---

## 3. Tag + GitHub Release

```bash
git checkout main
git pull github main

git tag -a v0.1.1 -m "v0.1.1 — first public try path"
git push github v0.1.1

gh release create v0.1.1 \
  --repo svarm-dev/svarm \
  --title "v0.1.1 — first public try path" \
  --notes-file CHANGELOG.md \
  docs/screenshots/board-seeded.png \
  docs/screenshots/card-running.png \
  docs/screenshots/dashboard.png
```

Release body = `CHANGELOG.md` (no separate notes file). Edit the GitHub release blurb in the UI if you want a shorter try-path intro.

If screenshots are not ready, omit the three PNG args (README will still 404 images until T4 — prefer waiting).

---

## 4. Visibility flip

Only after tag + release assets look right:

```bash
gh repo edit svarm-dev/svarm --visibility public
```

Confirm:

```bash
gh repo view svarm-dev/svarm --json visibility,description,repositoryTopics,latestRelease
```

Already set (leave unless wrong): description, topics (`ai-agents`, `elixir`, `phoenix`, `orchestration`, `self-hosted`, `devops`). Homepage can stay the GitHub tree until `svarm.dev` lands.

Private MIT is fine for dogfood; cold first-time users need **public + tag + screenshots**.

---

## 5. After public

- [ ] Open the clone URL from a logged-out browser / private window  
- [ ] Follow README path **A** cold (or trust a colleague to)  
- [ ] Vault Ops: check off remaining launch items; log dogfood in Dogfooding if you attach a real receipt  
- [ ] Optional later: Discussions, `SECURITY.md`, `CONTRIBUTING.md` — not required for 0.1.x  

---

## Do not

- Tag from a dirty worktree or a feature branch name strangers will clone  
- Push the release only to Forge `origin` and forget `github`  
- Flip public before screenshots if README still shows broken image links as the hero proof  
- Put tokens, PEM paths with secrets, or dogfood `.env` contents in release notes  
- Promise Linear/Jira or “agnostic” beyond what Status documents  

## Quick command index

| Step | Command |
|------|---------|
| Tests | `mix precommit` · `mix ci` |
| Demo smoke | `docker compose --profile demo up --build` |
| Health | `curl -sf http://localhost:4000/health` |
| Tag | `git tag -a v0.1.1 -m "…" && git push github v0.1.1` |
| Release | `gh release create v0.1.1 --repo svarm-dev/svarm …` |
| Public | `gh repo edit svarm-dev/svarm --visibility public` |
