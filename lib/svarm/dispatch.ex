defmodule Svarm.Dispatch do
  @moduledoc """
  Decomposed tasks → kanban.db.

  Keeps an explicit task assignee when present; otherwise routes via ProfileRouter.
  Auto-wires dependencies: priority N tasks depend on all priority N-1 tasks.
  """
  alias Svarm.ProfileRouter
  alias Svarm.Tracker

  def run(%{tasks: tasks, goal: goal}, opts \\ []) do
    tracker = Keyword.get(opts, :tracker, Tracker.Local)

    # Create all tasks first (without depends_on)
    created =
      Enum.map(tasks, fn task ->
        t = normalize_task(task)
        assignee = resolve_assignee(t)

        {:ok, issue} =
          tracker.create_issue(%{}, %{
            title: t[:title],
            body: t[:body],
            type: t[:type] || "code",
            assignee: assignee,
            priority: t[:priority] || 0,
            depends_on: [],
            created_by: "svarm",
            tenant: goal
          })

        issue
      end)

    wire_dependencies(created)

    {:ok, %{created_count: length(created), tasks: created}}
  end

  defp normalize_task(task) do
    get = &(Map.get(task, &1) || Map.get(task, Atom.to_string(&1)))

    %{
      title: get.(:title),
      body: get.(:body),
      type: get.(:type),
      assignee: get.(:assignee),
      priority: get.(:priority)
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

  defp wire_dependencies(created) do
    by_priority = Enum.group_by(created, & &1.priority)
    max_priority = Map.keys(by_priority) |> Enum.max(fn -> 0 end)

    for p <- 2..max_priority//1,
        lower_ids = Map.get(by_priority, p - 1, []) |> Enum.map(& &1.id),
        lower_ids != [] do
      higher_ids = Map.get(by_priority, p, []) |> Enum.map(& &1.id)
      Enum.each(higher_ids, &Svarm.KanbanBridge.update_depends_on(&1, lower_ids))
    end
  end
end
