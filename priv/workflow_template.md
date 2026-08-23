---
# tracker: where tickets live
# Default is local (SQLite board) — zero-key demo works out of the box.
tracker:
  kind: local                    # local | github
  active_states: ["todo", "in_progress"]
  # review is terminal for dispatch — human closes/merges after PR review
  terminal_states: ["done", "failed", "review"]

  # ═══════════════════════════════════════════════════════════════════
  # UNCOMMENT FOR GITHUB — set kind: github above, fill owner/repo,
  # and put GITHUB_TOKEN in .env. Leave kind: local for the zero-key demo.
  # ═══════════════════════════════════════════════════════════════════
  # owner: my-org
  # repo: my-project
  # auth: token                   # token (PAT) | app (GitHub App → {slug}[bot])
  # api_key: $GITHUB_TOKEN        # PAT mode; never a literal key
  # # App mode (bot identity; see docs/github-app.md):
  # # auth: app
  # # app_id: $SVARM_GITHUB_APP_ID
  # # installation_id: $SVARM_GITHUB_INSTALLATION_ID
  # # private_key_path: $SVARM_GITHUB_APP_KEY_PATH
  # required_labels: ["ai-task"]  # only issues with these labels are eligible
  # Status ↔ GitHub labels (optional). Defaults include
  # pending_approval → "status: pending-approval". Budget hold reuses that
  # status plus wait_reason — no extra GitHub label.
  # status_labels:
  #   "status: pending-approval": pending_approval
  # reverse_labels:
  #   pending_approval: "status: pending-approval"

polling:
  interval_ms: 30000
agent:
  max_concurrent_agents: 3
  max_retry_backoff_ms: 300000
  stall_timeout_ms: 2700000      # 45 min; keep >= PiRPC run timeout (stall also kill-trees the OS group)
approval:
  # off | all | untrusted — gate agent runs before first dispatch from todo
  # Default untrusted: real agents need human go-ahead.
  # Demo path: research + docs trusted; code gated so the approval chip is visible.
  mode: untrusted
  trusted_assignees: ["default", "demo_research", "demo_docs"]
workspace:
  root: ~/svarm_workspaces
  # isolation: path              # default — directory under root
  # isolation: worktree          # git worktree per ticket (requires git_repo)
  # git_repo: ~/src/my-app       # source repo for worktree mode
# Optional spend caps (unset = no stop). Mode hard skips spawn; hold parks for overage approval.
# budget:
#   max_usd_per_ticket: 5
#   max_usd_per_day: 25
#   mode: hard                   # hard | hold
---

You are an autonomous engineer. Complete the task below on a new branch,
verify, open a pull request, and stop. Do **not** merge.

Workflow:
1. Configure git: `gh auth setup-git`
2. Clone the repo: `gh repo clone OWNER/REPO .` (if the workspace is empty)
3. Create a branch: `git checkout -b svarm/{{issue.source_id}}`
4. Implement the changes described below
5. Run project tests and lint if present; if they fail, exit non-zero
6. Commit with a descriptive message referencing the issue
7. Push: `git push -u origin HEAD`
8. Open a PR against the default branch (`gh pr create --fill` or equivalent)
9. Summarize what you changed and what you verified
10. Do **not** merge the PR and do **not** push to main/master

Task: {{issue.title}} (issue #{{issue.source_id}}, id {{issue.id}})
Attempt: {{attempt}}

Description:
{{issue.description}}
