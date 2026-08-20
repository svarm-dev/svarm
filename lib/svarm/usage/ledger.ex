defmodule Svarm.Usage.Ledger do
  @moduledoc """
  Append-only usage ledger. Writes are immutable — never update or delete.
  Corrections are new records referencing the original run_id.

  Iron Law #1: LEDGER IS APPEND-ONLY.
  """
  import Ecto.Query, only: [from: 2]

  alias Svarm.Repo
  alias Svarm.Usage.Record

  @doc """
  Append a usage record. Returns the inserted record.
  """
  def append(attrs) when is_map(attrs) do
    id = "use_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)

    %Record{
      id: id,
      run_id: Map.fetch!(attrs, :run_id),
      task_id: Map.fetch!(attrs, :task_id),
      tenant: Map.get(attrs, :tenant),
      source: Map.fetch!(attrs, :source),
      provider: Map.get(attrs, :provider),
      model_id: Map.get(attrs, :model_id),
      prompt_tokens: Map.get(attrs, :prompt_tokens),
      completion_tokens: Map.get(attrs, :completion_tokens),
      estimated: Map.get(attrs, :estimated, false),
      provider_cost_usd: Map.get(attrs, :provider_cost_usd),
      recorded_at: System.monotonic_time(:millisecond),
      inserted_at: DateTime.utc_now()
    }
    |> Repo.insert!()
  end

  @doc """
  Returns all records for a given task, newest first.
  """
  def for_task(task_id) do
    from(r in Record, where: r.task_id == ^task_id, order_by: [desc: r.recorded_at])
    |> Repo.all()
  end

  @doc """
  Returns all records for the given task ids (any order). Empty input → [].
  """
  def for_tasks([]), do: []

  def for_tasks(task_ids) when is_list(task_ids) do
    from(r in Record, where: r.task_id in ^task_ids)
    |> Repo.all()
  end

  @doc """
  Returns records with wall-clock `inserted_at` on the given UTC calendar day.
  Rows with nil `inserted_at` (legacy backfill) are excluded.
  """
  def for_utc_day(%Date{} = day) do
    start_dt = DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")
    end_dt = DateTime.add(start_dt, 86_400, :second)

    from(r in Record,
      where: not is_nil(r.inserted_at) and r.inserted_at >= ^start_dt and r.inserted_at < ^end_dt,
      order_by: [desc: r.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns aggregate token counts since a given unix timestamp.
  """
  def totals_since(since_unix) when is_integer(since_unix) do
    from(r in Record,
      where: r.recorded_at >= ^since_unix,
      select: %{
        prompt: sum(r.prompt_tokens),
        completion: sum(r.completion_tokens),
        count: count(r.id)
      }
    )
    |> Repo.one()
  end

  @doc """
  Returns all records since a given monotonic timestamp (ms), newest first.
  """
  def records_since(since_mono) when is_integer(since_mono) do
    from(r in Record,
      where: r.recorded_at >= ^since_mono,
      order_by: [desc: r.recorded_at]
    )
    |> Repo.all()
  end

  @doc """
  Returns all records for a given tenant (goal), newest first.
  """
  def for_tenant(tenant) do
    from(r in Record, where: r.tenant == ^tenant, order_by: [desc: r.recorded_at])
    |> Repo.all()
  end

  @doc """
  Returns all usage records (no tenant filter).

  Prefer cost-group aggregates for dashboards/session totals; this is for
  export and rare full dumps.
  """
  def list_all do
    from(r in Record, order_by: [desc: r.recorded_at])
    |> Repo.all()
  end

  @doc """
  SQL cost groups for the whole ledger (session window).

  One row per `{provider, model_id}`. Does not materialize individual records.
  """
  def session_cost_groups do
    cost_groups_query(Record)
    |> Repo.all()
  end

  @doc """
  SQL cost groups for records with wall-clock `inserted_at >= since`.
  Rows with nil `inserted_at` are excluded.
  """
  def cost_groups_since_inserted_at(%DateTime{} = since) do
    from(r in Record,
      where: not is_nil(r.inserted_at) and r.inserted_at >= ^since
    )
    |> cost_groups_query()
    |> Repo.all()
  end

  @doc """
  SQL cost groups for wall-clock UTC calendar day (excludes nil `inserted_at`).
  """
  def cost_groups_for_utc_day(%Date{} = day) do
    start_dt = DateTime.new!(day, ~T[00:00:00.000000], "Etc/UTC")
    end_dt = DateTime.add(start_dt, 86_400, :second)

    from(r in Record,
      where: not is_nil(r.inserted_at) and r.inserted_at >= ^start_dt and r.inserted_at < ^end_dt
    )
    |> cost_groups_query()
    |> Repo.all()
  end

  @doc """
  SQL cost groups for a set of tasks, grouped by task + provider + model.

  Empty `task_ids` → []. Does not issue a query.
  """
  def cost_groups_for_tasks([]), do: []

  def cost_groups_for_tasks(task_ids) when is_list(task_ids) do
    from(r in Record, where: r.task_id in ^task_ids)
    |> task_cost_groups_query()
    |> Repo.all()
  end

  @doc """
  SQL cost groups for records with wall-clock `inserted_at >= since`,
  grouped by task + provider + model. Nil `inserted_at` excluded.
  """
  def task_cost_groups_since_inserted_at(%DateTime{} = since) do
    from(r in Record,
      where: not is_nil(r.inserted_at) and r.inserted_at >= ^since
    )
    |> task_cost_groups_query()
    |> Repo.all()
  end

  @doc """
  SQL cost groups for the whole ledger, grouped by task + provider + model.
  """
  def task_cost_groups_all do
    task_cost_groups_query(Record) |> Repo.all()
  end

  # --- private: group-by aggregates for cost (provider bill + rate-table tokens) ---

  defp cost_groups_query(queryable) do
    from(r in queryable,
      group_by: [r.provider, r.model_id],
      select: %{
        provider: r.provider,
        model_id: r.model_id,
        billed_usd:
          sum(
            fragment(
              "CASE WHEN ? IS NOT NULL THEN ? ELSE 0.0 END",
              r.provider_cost_usd,
              r.provider_cost_usd
            )
          ),
        rate_prompt:
          sum(
            fragment(
              "CASE WHEN ? IS NULL THEN COALESCE(?, 0) ELSE 0 END",
              r.provider_cost_usd,
              r.prompt_tokens
            )
          ),
        rate_completion:
          sum(
            fragment(
              "CASE WHEN ? IS NULL THEN COALESCE(?, 0) ELSE 0 END",
              r.provider_cost_usd,
              r.completion_tokens
            )
          ),
        prompt_tokens: sum(fragment("COALESCE(?, 0)", r.prompt_tokens)),
        completion_tokens: sum(fragment("COALESCE(?, 0)", r.completion_tokens)),
        record_count: count(r.id),
        unbilled_count:
          sum(fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", r.provider_cost_usd))
      }
    )
  end

  defp task_cost_groups_query(queryable) do
    from(r in queryable,
      group_by: [r.task_id, r.provider, r.model_id],
      select: %{
        task_id: r.task_id,
        provider: r.provider,
        model_id: r.model_id,
        billed_usd:
          sum(
            fragment(
              "CASE WHEN ? IS NOT NULL THEN ? ELSE 0.0 END",
              r.provider_cost_usd,
              r.provider_cost_usd
            )
          ),
        rate_prompt:
          sum(
            fragment(
              "CASE WHEN ? IS NULL THEN COALESCE(?, 0) ELSE 0 END",
              r.provider_cost_usd,
              r.prompt_tokens
            )
          ),
        rate_completion:
          sum(
            fragment(
              "CASE WHEN ? IS NULL THEN COALESCE(?, 0) ELSE 0 END",
              r.provider_cost_usd,
              r.completion_tokens
            )
          ),
        prompt_tokens: sum(fragment("COALESCE(?, 0)", r.prompt_tokens)),
        completion_tokens: sum(fragment("COALESCE(?, 0)", r.completion_tokens)),
        record_count: count(r.id),
        unbilled_count:
          sum(fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", r.provider_cost_usd))
      }
    )
  end
end
