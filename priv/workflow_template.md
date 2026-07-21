---
# tracker: where tickets live
tracker:
  kind: local                    # local | github (Linear, Jira: Pro/Team)
  active_states: ["todo", "in_progress"]
  # review is terminal for dispatch — human closes/merges after PR review
  terminal_states: ["done", "failed", "review"]

  # GitHub tracker config (kind: github):
  # owner: my-org
  # repo: my-project
  # auth: token                   # token (PAT) | app (GitHub App → {slug}[bot])
  # api_key: $GITHUB_TOKEN        # PAT mode; never a literal key
  # # App mode (recommended — bot identity; name the App anything free, e.g. svarm-bee):
  # # auth: app
  # # app_id: $SVARM_GITHUB_APP_ID
  # # installation_id: $SVARM_GITHUB_INSTALLATION_ID   # optional; resolved via API
  # # private_key_path: $SVARM_GITHUB_APP_KEY_PATH     # path to PEM
  # required_labels: ["ai-task"]  # only issues with these labels are eligible

polling:
  interval_ms: 30000
agent:
  max_concurrent_agents: 3
  max_retry_backoff_ms: 300000
  stall_timeout_ms: 300000       # kill stalled agents after N ms
approval:
  # off | all | untrusted — gate agent runs before first dispatch from todo
  # Default untrusted: real agents need human go-ahead; demo_* / default skip.
  mode: untrusted
  trusted_assignees: ["default", "demo_research", "demo_code", "demo_docs"]
workspace:
  root: ~/svarm_workspaces
---

You are an autonomous engineer. Complete the task below on a new branch,
verify, open a pull request, and stop. Do **not** merge.

Workflow:
1. Configure git: `gh auth setup-git`
2. Clone the repo: `gh repo clone OWNER/REPO .` (if the workspace is empty)
3. Create a branch: `git checkout -b svarm/{{issue.id}}`
4. Implement the changes described below
5. Run project tests and lint if present; if they fail, exit non-zero
6. Commit with a descriptive message referencing the issue
7. Push: `git push -u origin HEAD`
8. Open a PR against the default branch (`gh pr create --fill` or equivalent)
9. Summarize what you changed and what you verified
10. Do **not** merge the PR and do **not** push to main/master

Task: {{issue.title}} ({{issue.id}})
Attempt: {{attempt}}

Description:
{{issue.description}}
