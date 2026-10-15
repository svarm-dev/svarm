defmodule Svarm.Usage.Outcomes do
  @moduledoc """
  Query-time spend attribution by outcome bucket.

  The ledger stays append-only — this module never updates or deletes rows.
  Callers supply `%{task_id => status}` (from `Board.list_tasks/0` or a
  tracker issue list). Classification is status-based, plus a GitHub PR
  merge signal when coordination has a recorded PR:

  | Bucket | Meaning (v1) |
  |--------|----------------|
  | `:merged` | Status `done`, **or** GitHub PR `merged: true` while the ticket is still `review` |
  | `:in_review` | Status `review` and the PR is not known-merged |
  | `:other` | Any other status, or spend with no status map entry |

  **Honesty limits:** Local tracker and tickets without `pr_owner` /
  `pr_repo` / `pr_number` stay status-based (`done` = success). Closed-unmerged
  PRs, missing GitHub auth, and API/network errors do **not** invent a merge —
  they keep the status bucket. Costs may be estimated (rate table / unbilled).
  """

  alias Svarm.{Coordination, Settings, Workflow}
  alias Svarm.Tracker.GitHub.HTTP
  alias Svarm.Usage.{Ledger, Query, Receipt}
  alias Svarm.Workflow.Config, as: WorkflowConfig

  @outcomes [:merged, :in_review, :other]

  @doc "Ordered outcome atoms for docs and dashboards."
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  @doc "Classify a kanban/tracker status string into an outcome bucket."
  @spec classify_status(term()) :: :merged | :in_review | :other
  def classify_status("done"), do: :merged
  def classify_status("review"), do: :in_review
  def classify_status(_), do: :other

  @doc """
  Attribute ledger spend to outcome buckets.

  Options:
  - `:since` — `%DateTime{}` wall-clock filter on `inserted_at` (nil = all rows)
  - `:task_statuses` — `%{task_id => status}` (required for meaningful buckets)
  - `:task_ids` — optional enumerable of task ids to include (scopes ledger + status)
  - `:tracker_config` — GitHub tracker config for PR `merged` lookups (default:
    workflow + Settings overlay). Local kind skips GitHub.
  - `:req` — Req module override (tests)

  Returns:

      %{
        since: DateTime.t() | nil,
        by_outcome: %{merged: summary(), in_review: summary(), other: summary()},
        by_task: %{optional(String.t()) => task_summary()},
        task_count: non_neg_integer()
      }

  Each bucket summary includes `total_cost_usd`, `estimated`, `record_count`,
  `task_count`, `prompt_tokens`, `completion_tokens`. Each `by_task` entry is
  the same cost fields plus `outcome`. Estimated is true when any contributing
  group was rate-table / unbilled.

  Callers that need per-agent (or other) slices should group `by_task` in
  memory — do not call `by_outcome/1` again for the same snapshot.
  """
  @spec by_outcome(keyword()) :: map()
  def by_outcome(opts \\ []) when is_list(opts) do
    since = Keyword.get(opts, :since)
    statuses = opts |> Keyword.get(:task_statuses, %{}) |> normalize_statuses()
    task_id_filter = opts |> Keyword.get(:task_ids) |> normalize_task_id_filter()

    groups =
      case since do
        %DateTime{} = dt -> Ledger.task_cost_groups_since_inserted_at(dt)
        _ -> Ledger.task_cost_groups_all()
      end

    groups =
      if task_id_filter do
        Enum.filter(groups, &MapSet.member?(task_id_filter, &1.task_id))
      else
        groups
      end

    by_task =
      groups
      |> Enum.group_by(& &1.task_id)
      |> Map.new(fn {task_id, task_groups} ->
        {task_id, summarize_task_groups(task_groups)}
      end)

    empty = empty_summary()
    merged_flags = github_merged_flags(Map.keys(by_task), statuses, opts)

    by_task =
      Map.new(by_task, fn {task_id, summary} ->
        outcome = classify_task(task_id, Map.get(statuses, task_id), merged_flags)
        {task_id, Map.put(summary, :outcome, outcome)}
      end)

    by_outcome =
      Enum.reduce(by_task, Map.new(@outcomes, &{&1, empty}), fn {_task_id, summary}, acc ->
        Map.update!(acc, summary.outcome, &merge_summaries(&1, summary))
      end)

    %{
      since: if(match?(%DateTime{}, since), do: since, else: nil),
      by_outcome: by_outcome,
      by_task: by_task,
      task_count: map_size(by_task)
    }
  end

  defp normalize_task_id_filter(nil), do: nil
  defp normalize_task_id_filter([]), do: MapSet.new()

  defp normalize_task_id_filter(ids) when is_list(ids) do
    ids |> Enum.filter(&is_binary/1) |> MapSet.new()
  end

  defp normalize_task_id_filter(%MapSet{} = set), do: set
  defp normalize_task_id_filter(_), do: nil

  defp normalize_statuses(map) when is_map(map) do
    Map.new(map, fn
      {id, status} when is_binary(id) -> {id, status}
      {id, status} -> {to_string(id), status}
    end)
  end

  defp normalize_statuses(_), do: %{}

  defp classify_task(task_id, status, flags) do
    case Map.get(flags, task_id) do
      true -> :merged
      _ -> classify_status(status)
    end
  end

  # Query-time GitHub `merged` for review tickets that recorded a PR.
  # Fail closed: local / no PR / no auth / API error → status bucket.
  defp github_merged_flags(task_ids, statuses, opts) do
    candidates = pr_review_candidates(task_ids, statuses)

    case github_client(candidates, opts) do
      {:ok, req, headers, req_opts} ->
        fetch_merged_flags(candidates, req, headers, req_opts)

      :skip ->
        %{}
    end
  end

  defp pr_review_candidates(task_ids, statuses) do
    review_ids =
      Enum.filter(task_ids, &(classify_status(Map.get(statuses, &1)) == :in_review))

    coords = Coordination.get_many(review_ids)

    Enum.flat_map(review_ids, fn task_id ->
      case pr_triple(Map.get(coords, task_id)) do
        nil -> []
        triple -> [{task_id, triple}]
      end
    end)
  end

  defp pr_triple(%{pr_owner: owner, pr_repo: repo, pr_number: number})
       when is_binary(owner) and owner != "" and is_binary(repo) and repo != "" and
              is_integer(number) and number > 0 do
    {owner, repo, number}
  end

  defp pr_triple(_), do: nil

  defp github_client([], _opts), do: :skip

  defp github_client(_candidates, opts) do
    config = tracker_config(opts)
    headers = github_tracker?(config) && HTTP.headers(config)

    cond do
      not is_list(headers) -> :skip
      not Keyword.has_key?(headers, :authorization) -> :skip
      true -> {:ok, Keyword.get(opts, :req, Req), headers, HTTP.req_opts(opts)}
    end
  end

  defp tracker_config(opts) do
    case Keyword.get(opts, :tracker_config) do
      %{} = config -> config
      _ -> default_tracker_config()
    end
  end

  defp default_tracker_config do
    workflow = Workflow.Store.get()
    cfg = if workflow, do: WorkflowConfig.from(workflow), else: %{}
    Settings.Resolve.tracker_overlay(cfg[:tracker_config] || %{})
  end

  defp github_tracker?(%{kind: :github}), do: true
  defp github_tracker?(_), do: false

  defp fetch_merged_flags(candidates, req, headers, req_opts) do
    merged_by_pr =
      candidates
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
      |> Map.new(fn {owner, repo, number} = key ->
        merged? =
          case HTTP.pr_merged(req, owner, repo, number, headers, req_opts) do
            {:ok, true} -> true
            _ -> false
          end

        {key, merged?}
      end)

    Map.new(candidates, fn {task_id, key} ->
      {task_id, Map.get(merged_by_pr, key) == true}
    end)
  end

  defp empty_summary do
    Map.put(Receipt.empty_summary(), :task_count, 0)
  end

  defp merge_summaries(a, b) do
    a
    |> then(&Receipt.combine([&1, b]))
    |> Map.put(:task_count, num(a, :task_count) + 1)
  end

  defp num(map, key) do
    case Map.get(map, key) do
      n when is_number(n) -> n
      _ -> 0
    end
  end

  defp summarize_task_groups(groups), do: Query.summarize_groups(groups)
end
