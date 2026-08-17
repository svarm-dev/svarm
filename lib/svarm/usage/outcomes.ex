defmodule Svarm.Usage.Outcomes do
  @moduledoc """
  Query-time spend attribution by outcome bucket.

  The ledger stays append-only — this module never updates or deletes rows.
  Callers supply `%{task_id => status}` (from `Board.list_tasks/0` or a
  tracker issue list). Classification is intentionally status-based:

  | Bucket | Meaning (v1) |
  |--------|----------------|
  | `:merged` | Task status `done` (human accepted / closed) |
  | `:in_review` | Task status `review` |
  | `:other` | Any other status, or spend with no status map entry |

  **Honesty limits:** v1 does **not** call GitHub to see if a PR is merged.
  A GitHub issue still labeled `review` after merge counts as `:in_review`
  until the tracker status moves. Local board **Mark done** → `:merged`.
  """

  alias Svarm.Usage.{Ledger, Rates}

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

  Returns:

      %{
        since: DateTime.t() | nil,
        by_outcome: %{merged: summary(), in_review: summary(), other: summary()},
        task_count: non_neg_integer()
      }

  Each summary includes `total_cost_usd`, `estimated`, `record_count`,
  `task_count`, `prompt_tokens`, `completion_tokens`. Estimated is true when
  any contributing group was rate-table / unbilled.
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

    by_outcome =
      Enum.reduce(by_task, Map.new(@outcomes, &{&1, empty}), fn {task_id, summary}, acc ->
        outcome = classify_status(Map.get(statuses, task_id))
        Map.update!(acc, outcome, &merge_summaries(&1, summary))
      end)

    %{
      since: if(match?(%DateTime{}, since), do: since, else: nil),
      by_outcome: by_outcome,
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

  defp empty_summary do
    %{
      total_cost_usd: 0.0,
      estimated: false,
      record_count: 0,
      task_count: 0,
      prompt_tokens: 0,
      completion_tokens: 0
    }
  end

  defp merge_summaries(a, b) do
    %{
      total_cost_usd: Float.round((a.total_cost_usd || 0.0) + (b.total_cost_usd || 0.0), 4),
      estimated: a.estimated or b.estimated,
      record_count: (a.record_count || 0) + (b.record_count || 0),
      task_count: (a.task_count || 0) + 1,
      prompt_tokens: (a.prompt_tokens || 0) + (b.prompt_tokens || 0),
      completion_tokens: (a.completion_tokens || 0) + (b.completion_tokens || 0)
    }
  end

  defp summarize_task_groups(groups) do
    {total, count, estimated, prompt, completion} =
      Enum.reduce(groups, {0.0, 0, false, 0, 0}, fn group,
                                                    {total_acc, count_acc, est_acc, p_acc, c_acc} ->
        cost = group_cost_usd(group)

        {
          total_acc + cost,
          count_acc + (group.record_count || 0),
          est_acc or unbilled?(group),
          p_acc + (group.prompt_tokens || 0),
          c_acc + (group.completion_tokens || 0)
        }
      end)

    %{
      total_cost_usd: Float.round(total, 4),
      estimated: estimated,
      record_count: count,
      prompt_tokens: prompt,
      completion_tokens: completion
    }
  end

  defp group_cost_usd(group) do
    billed = (group.billed_usd || 0) * 1.0

    case Rates.cost_usd(
           group.provider,
           group.model_id,
           group.rate_prompt || 0,
           group.rate_completion || 0
         ) do
      {:ok, rate} -> billed + rate
      _ -> billed
    end
  end

  defp unbilled?(group), do: (group.unbilled_count || 0) > 0
end
