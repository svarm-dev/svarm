defmodule Svarm.Test.FakeTracker do
  @moduledoc false
  # In-memory Tracker behaviour for Approval and Dispatch tests (no live GitHub).

  @behaviour Svarm.Tracker

  alias Svarm.Issue

  @table :svarm_fake_tracker
  @meta_table :svarm_fake_tracker_meta

  def setup do
    ensure_table()
    ensure_meta_table()
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@meta_table)
    :ok
  end

  def last_create_config do
    ensure_meta_table()

    case :ets.lookup(@meta_table, :last_create_config) do
      [{:last_create_config, config}] -> config
      [] -> nil
    end
  end

  def create_configs do
    ensure_meta_table()

    case :ets.lookup(@meta_table, :create_configs) do
      [{:create_configs, list}] -> Enum.reverse(list)
      [] -> []
    end
  end

  def put(%Issue{} = issue) do
    ensure_table()
    true = :ets.insert(@table, {issue.id, issue})
    issue
  end

  def get(id) do
    ensure_table()

    case :ets.lookup(@table, id) do
      [{^id, issue}] -> issue
      [] -> nil
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        :ok
    end
  end

  defp ensure_meta_table do
    case :ets.whereis(@meta_table) do
      :undefined ->
        :ets.new(@meta_table, [:named_table, :public, :set])

      _ ->
        :ok
    end
  end

  @impl true
  def list_eligible(_config), do: {:ok, []}

  @impl true
  def get_issue(_config, id) do
    case get(id) do
      nil -> {:error, :not_found}
      issue -> {:ok, issue}
    end
  end

  @impl true
  def get_issues(config, ids) when is_list(ids) do
    {:ok, Map.new(Enum.uniq(ids), fn id -> {id, get_issue(config, id)} end)}
  end

  @impl true
  def list_issues(_config, filters \\ []) do
    ensure_table()
    status = Keyword.get(filters, :status)

    issues =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, issue} -> issue end)
      |> then(fn list ->
        if status, do: Enum.filter(list, &(&1.status == status)), else: list
      end)

    {:ok, issues}
  end

  @impl true
  def create_issue(config, attrs) do
    ensure_table()
    ensure_meta_table()
    record_create_config(config)

    id =
      case Map.get(attrs, :id) do
        id when is_binary(id) and id != "" -> id
        _ -> "fake_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      end

    issue =
      struct(
        Issue,
        attrs
        |> Map.put(:id, id)
        |> Map.put_new(:status, "todo")
        |> Map.put_new(:depends_on, [])
        |> Map.to_list()
      )

    {:ok, put(issue)}
  end

  @impl true
  def update_status(_config, id, status) do
    case get(id) do
      nil ->
        :ok

      issue ->
        put(%{issue | status: status})
        :ok
    end
  end

  @impl true
  def update_attempts(_config, id, attempts) do
    case get(id) do
      nil ->
        :ok

      issue ->
        put(%{issue | attempts: attempts})
        :ok
    end
  end

  @impl true
  def update_depends_on(_config, id, depends_on) when is_list(depends_on) do
    case get(id) do
      nil ->
        {:error, :not_found}

      issue ->
        put(%{issue | depends_on: depends_on})
        :ok
    end
  end

  @impl true
  def claim(_config, _id), do: :ok

  @impl true
  def delete_all(_config) do
    setup()
    :ok
  end

  @impl true
  def post_run_summary(_config, _id, _summary), do: :ok

  defp record_create_config(config) do
    :ets.insert(@meta_table, {:last_create_config, config})

    prev =
      case :ets.lookup(@meta_table, :create_configs) do
        [{:create_configs, list}] -> list
        [] -> []
      end

    :ets.insert(@meta_table, {:create_configs, [config | prev]})
  end
end
