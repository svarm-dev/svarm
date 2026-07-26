defmodule Svarm.Test.FakeTracker do
  @moduledoc false
  # In-memory Tracker behaviour for Approval tests (no live GitHub).

  @behaviour Svarm.Tracker

  alias Svarm.Issue

  @table :svarm_fake_tracker

  def setup do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
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
  def create_issue(_config, attrs) do
    issue = struct(Issue, Map.to_list(attrs))
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
  def claim(_config, _id), do: :ok

  @impl true
  def delete_all(_config) do
    setup()
    :ok
  end

  @impl true
  def post_run_summary(_config, _id, _summary), do: :ok
end
