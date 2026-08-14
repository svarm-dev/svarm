defmodule Svarm.Board do
  @moduledoc """
  Read API for the kanban dashboard. LiveViews call here — not the tracker directly.
  """
  alias Svarm.{Orchestrator, Settings, Tracker, Workflow}
  alias Svarm.Workflow.Config, as: WorkflowConfig

  @default_columns [
    "todo",
    "pending_approval",
    "in_progress",
    "review",
    "done",
    "failed"
  ]

  @doc """
  Returns the tracker adapter to use. Resolved from WORKFLOW.md config,
  same as the orchestrator. Falls back to local kanban.
  """
  def tracker do
    tc = tracker_config()

    case tc[:kind] || :local do
      :github -> Tracker.GitHub
      _ -> Tracker.Local
    end
  end

  @doc """
  List tasks for board/dashboard card paths.

  Omits full issue `body` (card UI never shows it). Use `get_task/1` when the
  body is required (agent dispatch, approvals detail).
  """
  def list_tasks(filters \\ []) do
    config = tracker_config()
    filters = Keyword.put(filters, :include_body, false)
    {:ok, issues} = tracker().list_issues(config, filters)
    tasks = Enum.map(issues, &issue_to_card_map/1)
    attach_coordination(tasks)
  end

  def get_task(id) do
    config = tracker_config()

    case tracker().get_issue(config, id) do
      {:ok, issue} ->
        issue
        |> issue_to_map()
        |> attach_coordination_one()

      {:error, _} ->
        nil
    end
  end

  defp tracker_config do
    workflow = Workflow.Store.get()
    cfg = if workflow, do: WorkflowConfig.from(workflow), else: %{}
    base = cfg[:tracker_config] || %{}
    Settings.Resolve.tracker_overlay(base)
  end

  def orchestrator_status do
    Orchestrator.status()
  end

  @doc """
  Agent configs for board UI (agents.toml + Settings overrides).

  LiveViews load agents through this read facade — not `AgentRunner` directly.
  Returns a map of agent name => config, or `%{}` if load fails.
  """
  def list_agents do
    case Svarm.AgentRunner.load_agents() do
      agents when is_map(agents) -> agents
      _ -> %{}
    end
  end

  @doc """
  Snapshot of this install for homepage and first-run checklist.

  Returns a plain map: tracker, workflow path, agents, tasks, approvals.
  """
  def instance_status do
    workflow = Workflow.Store.get()
    cfg = if workflow, do: WorkflowConfig.from(workflow), else: %{}
    tracker = Settings.Resolve.tracker_overlay(cfg[:tracker_config] || %{})
    agents = list_agents()
    tasks = safe_list_tasks()
    approval = approval_mode(workflow)
    setup = Settings.status()

    %{
      tracker_kind: tracker[:kind] || :local,
      tracker_label: tracker_label(tracker),
      tracker_source: setup.tracker_source,
      workflow_path: workflow && workflow.path,
      workflow_loaded?: match?(%Workflow{}, workflow),
      agent_count: map_size(agents),
      task_count: length(tasks),
      approval_mode: approval,
      approvals_auth?: approvals_auth_configured?(),
      demo_routes: Svarm.Demo.routes_enabled?(),
      empty?: tasks == [],
      provider_configured?: setup.provider_configured?,
      tracker_ready?: setup.tracker_ready?,
      setup_complete?: setup.setup_complete?
    }
  end

  defp tracker_label(%{kind: :github} = t),
    do: "github:#{t[:owner] || "?"}/#{t[:repo] || "?"}"

  defp tracker_label(_), do: "local"

  defp approval_mode(%Workflow{config: config}) when is_map(config),
    do: get_in(config, ["approval", "mode"]) || "untrusted"

  defp approval_mode(_), do: "untrusted"

  defp approvals_auth_configured? do
    match?(
      %{username: u, password: p} when is_binary(u) and u != "" and is_binary(p) and p != "",
      Application.get_env(:svarm, :approvals_auth)
    ) or Application.get_env(:svarm, :dev_routes, false)
  end

  defp safe_list_tasks do
    list_tasks()
  rescue
    e in [DBConnection.ConnectionError, ErlangError, ArgumentError] ->
      _ = e
      []
  end

  @doc "Column ids in display order (workflow active + terminal, de-duplicated)."
  def column_ids do
    wf = Workflow.Store.get()

    {active, terminal} =
      case wf do
        %Workflow{} = wf ->
          cfg = WorkflowConfig.from(wf)
          {cfg.active_states, cfg.terminal_states}

        _ ->
          {["todo", "in_progress"], ["done", "failed", "review"]}
      end

    pending = Svarm.Approval.pending_status()

    (@default_columns ++ active ++ terminal ++ [pending])
    |> Enum.uniq()
    |> Enum.sort_by(&column_rank/1)
  end

  def group_by_status(tasks) when is_list(tasks) do
    cols = column_ids()

    grouped =
      tasks
      |> Enum.group_by(& &1.status, fn t -> t end)

    Map.new(cols, fn col ->
      {col, Map.get(grouped, col, [])}
    end)
  end

  @doc "Count of non-terminal tasks per assignee (for board at-a-glance)."
  def counts_by_assignee(tasks) when is_list(tasks) do
    tasks
    |> Enum.reject(&(&1.status in ["done", "failed"]))
    |> Enum.frequencies_by(&(&1.assignee || "default"))
  end

  @doc "Task counts grouped by kanban status."
  def counts_by_status(tasks) when is_list(tasks) do
    Enum.frequencies_by(tasks, & &1.status)
  end

  @doc """
  Why this task is waiting — human gates first, then agent activity.

  Returns `:approval | :ci_circuit | :changes_requested | :review | :running | :failed | nil`.

  `:ci_circuit` wins over `:changes_requested` and plain `:review` when the CI
  resume circuit is open (ticket stays in `review` so humans can still merge).
  `:changes_requested` wins over plain `:review` when GitHub review polling
  recorded a latest submitted CHANGES_REQUESTED (detector only; no auto-spawn).
  """
  def wait_reason(%{status: "pending_approval"}), do: :approval

  def wait_reason(%{status: "review"} = task) do
    cond do
      circuit_open_for?(task) -> :ci_circuit
      changes_requested_for?(task) -> :changes_requested
      true -> :review
    end
  end

  def wait_reason(%{status: "in_progress"}), do: :running
  def wait_reason(%{status: "failed"}), do: :failed
  def wait_reason(_), do: nil

  # Prefer preloaded field from list_tasks/get_task; fall back to one query.
  defp circuit_open_for?(task) do
    case map_get(task, :ci_circuit_open) do
      true ->
        true

      false ->
        false

      _ ->
        id = map_get(task, :id)
        is_binary(id) and Svarm.Coordination.circuit_open?(id)
    end
  end

  defp changes_requested_for?(task) do
    if Map.has_key?(task, :review_decision) or Map.has_key?(task, "review_decision") do
      map_get(task, :review_decision) in ["changes_requested", :changes_requested]
    else
      id = map_get(task, :id)
      match?(%{review_decision: "changes_requested"}, id && Svarm.Coordination.get(id))
    end
  end

  @doc "Short UI label for `wait_reason/1`."
  def wait_reason_label(:approval), do: "Needs approval"
  def wait_reason_label(:ci_circuit), do: "CI retries exhausted"
  def wait_reason_label(:changes_requested), do: "Changes requested"
  def wait_reason_label(:review), do: "Needs review"
  def wait_reason_label(:running), do: "Running"
  def wait_reason_label(:failed), do: "Failed"
  def wait_reason_label(_), do: nil

  @doc """
  Counts of tickets blocked on humans.

  Returns `%{pending_approval: n, review: n, total: n}`.
  """
  def human_wait_summary(tasks) when is_list(tasks) do
    pending = Enum.count(tasks, &(&1.status == "pending_approval"))
    review = Enum.count(tasks, &(&1.status == "review"))
    %{pending_approval: pending, review: review, total: pending + review}
  end

  @doc "PR URL from coordination, run meta, or task map when known (no inventing)."
  def pr_url(task, meta \\ %{}) do
    [
      map_get(task, :pr_url),
      meta_get(meta, :pr_url),
      map_get(task, :pull_request_url),
      coord_pr_url_fallback(task)
    ]
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp coord_pr_url_fallback(task) do
    # Only hit Repo when list_tasks did not preload pr_url.
    case map_get(task, :pr_url) do
      url when is_binary(url) and url != "" -> nil
      _ -> fetch_coord_pr_url(map_get(task, :id))
    end
  end

  defp fetch_coord_pr_url(id) when is_binary(id) do
    case Svarm.Coordination.get(id) do
      %{pr_url: url} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp fetch_coord_pr_url(_), do: nil

  @doc "Reviewer login/name from task when tracker exposes it."
  def reviewer(task) do
    [map_get(task, :reviewer), map_get(task, :reviewer_login)]
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  @doc """
  Mark a task in `review` as `done` (human accepted the agent result).

  Used on the local board when there is no PR to open; also works after a GitHub PR review.
  """
  def complete_review(id) when is_binary(id) do
    config = tracker_config()
    adapter = tracker()

    case adapter.get_issue(config, id) do
      {:ok, %{status: "review"}} ->
        adapter.update_status(config, id, "done")
        :ok

      {:ok, _} ->
        {:error, :not_in_review}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp meta_get(meta, key) when is_map(meta) do
    Map.get(meta, key) || Map.get(meta, Atom.to_string(key))
  end

  defp meta_get(_, _), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil

  def refresh_snapshot do
    tasks = list_tasks()
    Svarm.Events.broadcast_tasks_snapshot(tasks)
    Svarm.Events.broadcast_orchestrator_status(orchestrator_status())
    tasks
  end

  # Full issue map (get_task / callers that need body).
  defp issue_to_map(%Svarm.Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      body: i.body,
      type: i.type,
      assignee: i.assignee,
      status: i.status,
      priority: i.priority,
      attempts: i.attempts,
      created_at: i.created_at,
      tenant: i.tenant
    }
  end

  # Card/list projection — never carry body into LiveView assigns.
  defp issue_to_card_map(%Svarm.Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      type: i.type,
      assignee: i.assignee,
      status: i.status,
      priority: i.priority,
      attempts: i.attempts,
      created_at: i.created_at,
      tenant: i.tenant
    }
  end

  # One query for the board: attach ci_circuit_open + review_decision + pr_url.
  defp attach_coordination(tasks) when is_list(tasks) do
    ids = Enum.map(tasks, & &1.id)
    by_id = Svarm.Coordination.get_many(ids)

    Enum.map(tasks, fn task ->
      merge_coord(task, Map.get(by_id, task.id))
    end)
  end

  defp attach_coordination_one(task) when is_map(task) do
    merge_coord(task, Svarm.Coordination.get(task.id))
  end

  defp merge_coord(task, nil) do
    task
    |> Map.put(:ci_circuit_open, false)
    |> Map.put(:review_decision, nil)
  end

  defp merge_coord(task, %Svarm.Coordination{} = c) do
    task
    |> Map.put(:ci_circuit_open, c.ci_circuit_open == true)
    |> Map.put(:review_decision, c.review_decision)
    |> then(fn t ->
      if is_binary(c.pr_url) and c.pr_url != "" do
        Map.put(t, :pr_url, c.pr_url)
      else
        t
      end
    end)
  end

  defp column_rank("todo"), do: 0
  defp column_rank("pending_approval"), do: 1
  defp column_rank("in_progress"), do: 2
  defp column_rank("review"), do: 3
  defp column_rank("done"), do: 4
  defp column_rank("failed"), do: 5
  defp column_rank(_), do: 50
end
