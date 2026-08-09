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
    :tenant
  ]

  def create_task(attrs), do: GenServer.call(__MODULE__, {:create, attrs})
  def get_task(id), do: GenServer.call(__MODULE__, {:get, id})

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

  def delete_all_tasks, do: GenServer.call(__MODULE__, :delete_all)

  def update_depends_on(id, depends_on),
    do: GenServer.call(__MODULE__, {:update_depends_on, id, depends_on})

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

    if count > 0 and field in [:status, :attempts] do
      case Repo.get(Task, id) do
        nil -> :ok
        task -> Events.broadcast_task_updated(task_to_map(task))
      end
    end

    {:reply, :ok, state}
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
      tenant: t.tenant
    }
  end
end
