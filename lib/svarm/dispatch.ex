defmodule Svarm.Dispatch do
  @moduledoc """
  Decomposed tasks → the active tracker.

  Keeps an explicit task assignee when present; otherwise routes via ProfileRouter.
  Auto-wires dependencies: priority N tasks depend on all priority N-1 tasks,
  passed into `create_issue` as `depends_on` (Local: KanbanBridge column;
  GitHub: issue-body marker). Expected tracker failures return `{:error, reason}`.
  """
  alias Svarm.ProfileRouter
  alias Svarm.Tracker

  def run(%{tasks: tasks, goal: goal}, opts \\ []) do
    {tracker, config} = Tracker.Resolve.from_opts(opts)

    tasks
    |> Enum.map(&normalize_task/1)
    |> Enum.group_by(& &1.priority)
    |> Enum.sort_by(fn {priority, _group} -> priority end)
    |> Enum.reduce_while({:ok, {[], %{}}}, &create_priority_group(&1, &2, tracker, config, goal))
    |> case do
      {:ok, {created, _by_priority}} ->
        {:ok, %{created_count: length(created), tasks: created}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_priority_group({priority, group}, {:ok, {acc, by_priority}}, tracker, config, goal) do
    depends_on =
      case Map.get(by_priority, priority - 1) do
        nil -> []
        issues -> Enum.map(issues, & &1.id)
      end

    case create_group(tracker, config, group, goal, depends_on) do
      {:ok, created} ->
        {:cont, {:ok, {acc ++ created, Map.put(by_priority, priority, created)}}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp create_group(tracker, config, group, goal, depends_on) do
    Enum.reduce_while(group, {:ok, []}, fn t, {:ok, acc} ->
      attrs = %{
        title: t[:title],
        body: t[:body],
        type: t[:type] || "code",
        assignee: resolve_assignee(t),
        priority: t[:priority] || 0,
        depends_on: depends_on,
        created_by: "svarm",
        tenant: goal
      }

      case tracker.create_issue(config, attrs) do
        {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, created} -> {:ok, Enum.reverse(created)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_task(task) do
    get = &(Map.get(task, &1) || Map.get(task, Atom.to_string(&1)))

    %{
      title: get.(:title),
      body: get.(:body),
      type: get.(:type),
      assignee: get.(:assignee),
      priority: get.(:priority) || 0
    }
  end

  defp resolve_assignee(%{assignee: assignee}) when is_binary(assignee) do
    case String.trim(assignee) do
      "" -> ProfileRouter.assign("")
      name -> name
    end
  end

  defp resolve_assignee(%{title: title, body: body}) do
    ProfileRouter.assign("#{title} #{body}")
  end
end
