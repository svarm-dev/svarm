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

  def create_task(attrs), do: GenServer.call(__MODULE__, {:create, attrs})
  def get_task(id), do: GenServer.call(__MODULE__, {:get, id})
  def list_tasks(filters \\ []), do: GenServer.call(__MODULE__, {:list, filters})
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

  def handle_call({:list, filters}, _from, state) do
    query = from(t in Task, order_by: [asc: t.priority, asc: t.created_at, asc: t.id])

    query =
      Enum.reduce(filters, query, fn {field, value}, q ->
        from(t in q, where: field(t, ^field) == ^value)
      end)

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
