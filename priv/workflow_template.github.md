---
# tracker: GitHub Issues (path B — real loop)
# Copy over WORKFLOW.md or merge into svarm-config/WORKFLOW.md after first boot.
tracker:
  kind: github
  owner: YOUR_GITHUB_USER_OR_ORG
  repo: YOUR_TEST_REPO
  auth: token
  api_key: $GITHUB_TOKEN
  required_labels: ["ai-task"]
  active_states: ["todo", "in_progress"]
  terminal_states: ["done", "failed", "review"]

polling:
  interval_ms: 30000
agent:
  max_concurrent_agents: 3
  max_retry_backoff_ms: 300000
  stall_timeout_ms: 300000
approval:
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
