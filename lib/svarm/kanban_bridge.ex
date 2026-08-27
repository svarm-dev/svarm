defmodule Svarm.KanbanBridge do
  @moduledoc """
  SQLite-backed kanban board (Ecto). The issue tracker for Svärm's Symphony loop:
  goals decompose into tasks here, the poll loop dispatches eligible tasks.
  """
  use GenServer

  alias Svarm.{Events, Repo}
  alias Svarm.Kanban.Task

  import Ecto.Query, only: [from: 2]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Card/list projection — omit body (large TEXT) unless callers need it.
  @card_fields [
    :id,
    :title,
    :type,
    :assignee,
    :status,
    :priority,
    :attempts,
    :depends_on,
    :created_by,
    :created_at,
    :tenant,
    :wait_reason,
    :pending_question
  ]

  def create_task(attrs), do: GenServer.call(__MODULE__, {:create, attrs})

  def get_task(id) do
    emit_call(:get, 1)
    GenServer.call(__MODULE__, {:get, id})
  end

  @doc """
  Fetch many tasks in one GenServer/Ecto round-trip (`WHERE id IN (...)`).

  Returns a map of found id => task map. Missing ids are omitted.
  An empty id list does not hit the database.
  """
  @spec get_tasks([String.t()]) :: %{String.t() => map()}
  def get_tasks(ids) when is_list(ids) do
    emit_call(:get_many, length(ids))
    GenServer.call(__MODULE__, {:get_many, ids})
  end

  @doc """
  List tasks matching filters.

  Options:
  - `:include_body` — when `false` (default `true`), skips loading the `body`
    column. Board/dashboard card paths pass `false`; approval UI and
    get_task/eligible keep full rows.
  """
  def list_tasks(filters \\ [], opts \\ [])

  def list_tasks(filters, opts) when is_list(filters) and is_list(opts) do
    GenServer.call(__MODULE__, {:list, filters, opts})
  end

  def fetch_eligible(active_states), do: GenServer.call(__MODULE__, {:eligible, active_states})
  def update_status(id, status), do: GenServer.call(__MODULE__, {:update, id, :status, status})

  def update_attempts(id, attempts),
    do: GenServer.call(__MODULE__, {:update, id, :attempts, attempts})

  @doc "Set or clear the durable `wait_reason` string on a task."
  def update_wait_reason(id, reason),
    do: GenServer.call(__MODULE__, {:update, id, :wait_reason, reason})

  def delete_all_tasks, do: GenServer.call(__MODULE__, :delete_all)

  def update_depends_on(id, depends_on),
    do: GenServer.call(__MODULE__, {:update_depends_on, id, depends_on})

  @doc """
  Persist a mid-run agent question on the task.

  Sets `wait_reason` to `"agent_question"` and stores `pending_question`.
  `attrs` must include a non-empty `prompt` (atom or string key). Optional
  `request_id`, `asked_at`, `method`, and `options` (select) are kept.
  Survives board refresh and restart.
  """
  @spec put_pending_question(String.t(), map()) :: {:ok, map()} | {:error, :not_found | :invalid}
  def put_pending_question(id, attrs) when is_binary(id) and is_map(attrs) do
    GenServer.call(__MODULE__, {:put_pending_question, id, attrs})
  end

  @doc "Clear mid-run wait reason and pending question payload."
  @spec clear_pending_question(String.t()) :: {:ok, map()} | {:error, :not_found}
  def clear_pending_question(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:clear_pending_question, id})
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create, attrs}, _from, state) do
    id = "sva_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    now = System.system_time(:second)

    task_struct =
      %Task{id: id, created_at: now}
      |> Task.changeset(attrs)
      |> Repo.insert!()

    task_map = task_to_map(task_struct)
    Events.broadcast_task_updated(task_map)
    {:reply, task_map, state}
  end

  @impl true
  def handle_call(:delete_all, _from, state) do
    Repo.delete_all(Task)
    {:reply, :ok, state}
  end

  def handle_call({:get, id}, _from, state) do
    task =
      case Repo.get(Task, id) do
        nil -> nil
        t -> task_to_map(t)
      end

    {:reply, task, state}
  end

  def handle_call({:get_many, ids}, _from, state) do
    ids = ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    tasks =
      if ids == [] do
        %{}
      else
        from(t in Task, where: t.id in ^ids)
        |> Repo.all()
        |> Map.new(fn t -> {t.id, task_to_map(t)} end)
      end

    {:reply, tasks, state}
  end

  def handle_call({:list, filters, opts}, _from, state) do
    include_body? = Keyword.get(opts, :include_body, true)

    query =
      from(t in Task, order_by: [asc: t.priority, asc: t.created_at, asc: t.id])

    query =
      Enum.reduce(filters, query, fn {field, value}, q ->
        from(t in q, where: field(t, ^field) == ^value)
      end)

    query =
      if include_body? do
        query
      else
        from(t in query, select: struct(t, ^@card_fields))
      end

    tasks =
      query
      |> Repo.all()
      |> Enum.map(&task_to_map/1)

    {:reply, tasks, state}
  end

  def handle_call({:eligible, active_states}, _from, state) do
    tasks =
      from(t in Task,
        where: t.status in ^active_states,
        order_by: [asc: t.priority, asc: t.created_at, asc: t.id]
      )
      |> Repo.all()
      |> Enum.map(&task_to_map/1)

    {:reply, tasks, state}
  end

  def handle_call({:update, id, field, value}, _from, state) do
    updates = [{field, value}]

    {count, _} =
      from(t in Task, where: t.id == ^id)
      |> Repo.update_all(set: updates)

    if count > 0 and field in [:status, :attempts, :wait_reason] do
      case Repo.get(Task, id) do
        nil -> :ok
        task -> Events.broadcast_task_updated(task_to_map(task))
      end
    end

    {:reply, :ok, state}
  end

  def handle_call({:put_pending_question, id, attrs}, _from, state) do
    case {Repo.get(Task, id), normalize_pending_question(attrs)} do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {_task, {:error, :invalid}} ->
        {:reply, {:error, :invalid}, state}

      {task, {:ok, payload}} ->
        {:ok, saved} =
          task
          |> Task.changeset(%{wait_reason: "agent_question", pending_question: payload})
          |> Repo.update()

        map = task_to_map(saved)
        Events.broadcast_task_updated(map)
        {:reply, {:ok, map}, state}
    end
  end

  def handle_call({:clear_pending_question, id}, _from, state) do
    case Repo.get(Task, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      task ->
        {:ok, saved} =
          task
          |> Task.changeset(%{wait_reason: nil, pending_question: nil})
          |> Repo.update()

        map = task_to_map(saved)
        Events.broadcast_task_updated(map)
        {:reply, {:ok, map}, state}
    end
  end

  def handle_call({:update_depends_on, id, depends_on}, _from, state) do
    {1, _} =
      from(t in Task, where: t.id == ^id)
      |> Repo.update_all(set: [depends_on: depends_on])

    case Repo.get(Task, id) do
      nil -> :ok
      task -> Events.broadcast_task_updated(task_to_map(task))
    end

    {:reply, :ok, state}
  end

  # -- helpers --

  defp emit_call(op, n) do
    :telemetry.execute([:svarm, :kanban_bridge, :call], %{count: 1, n: n}, %{op: op})
  end

  defp task_to_map(%Task{} = t) do
    %{
      id: t.id,
      title: t.title,
      body: t.body,
      type: t.type,
      assignee: t.assignee,
      status: t.status,
      priority: t.priority,
      attempts: t.attempts,
      depends_on: t.depends_on || [],
      created_at: t.created_at,
      tenant: t.tenant,
      wait_reason: t.wait_reason,
      pending_question: t.pending_question
    }
  end

  defp normalize_pending_question(attrs) when is_map(attrs) do
    prompt = map_get(attrs, :prompt)

    if is_binary(prompt) and String.trim(prompt) != "" do
      payload =
        %{
          "reason" => "agent_question",
          "prompt" => prompt,
          "request_id" => stringify_optional(map_get(attrs, :request_id)),
          "method" => stringify_optional(map_get(attrs, :method)),
          "options" => normalize_options(map_get(attrs, :options)),
          "asked_at" => map_get(attrs, :asked_at) || System.system_time(:second)
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

      {:ok, payload}
    else
      {:error, :invalid}
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp stringify_optional(nil), do: nil
  defp stringify_optional(value) when is_binary(value), do: value
  defp stringify_optional(value), do: to_string(value)

  defp normalize_options(nil), do: nil

  defp normalize_options(options) when is_list(options) do
    Enum.map(options, fn
      option when is_binary(option) ->
        option

      %{"label" => label, "value" => value} ->
        %{"label" => to_string(label), "value" => to_string(value)}

      %{label: label, value: value} ->
        %{"label" => to_string(label), "value" => to_string(value)}

      option when is_atom(option) ->
        Atom.to_string(option)

      option ->
        to_string(option)
    end)
  end

  defp normalize_options(_), do: nil
end
