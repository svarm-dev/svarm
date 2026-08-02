defmodule Svarm.Usage.Ledger do
  @moduledoc """
  Append-only usage ledger. Writes are immutable — never update or delete.
  Corrections are new records referencing the original run_id.

  Iron Law #1: LEDGER IS APPEND-ONLY.
  """
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
    import Ecto.Query, only: [from: 2]

    from(r in Record, where: r.task_id == ^task_id, order_by: [desc: r.recorded_at])
    |> Repo.all()
  end

  @doc """
  Returns records with wall-clock `inserted_at` on the given UTC calendar day.
  Rows with nil `inserted_at` (legacy backfill) are excluded.
  """
  def for_utc_day(%Date{} = day) do
    import Ecto.Query, only: [from: 2]

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
    import Ecto.Query, only: [from: 2]

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
    import Ecto.Query, only: [from: 2]

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
    import Ecto.Query, only: [from: 2]

    from(r in Record, where: r.tenant == ^tenant, order_by: [desc: r.recorded_at])
    |> Repo.all()
  end

  @doc """
  Returns all usage records (no tenant filter).
  """
  def list_all do
    import Ecto.Query, only: [from: 2]

    from(r in Record, order_by: [desc: r.recorded_at])
    |> Repo.all()
  end
end
