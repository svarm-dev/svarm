defmodule Svarm.Approval do
  @moduledoc """
  Human-in-the-loop gate before agent execution.

  Trust is workflow-driven: `approval.mode` and `approval.trusted_assignees`.
  Tasks held in kanban status `pending_approval` until approved.
  """

  alias Svarm.{ProfileRouter, Tracker}

  @status_pending "pending_approval"

  def pending_status, do: @status_pending

  @doc "Returns the tracker adapter to use."
  def tracker, do: Tracker.Local

  @doc "Parsed approval settings from workflow front matter."
  def config_from_map(config) when is_map(config) do
    mode =
      config
      |> get_in(["approval", "mode"])
      |> normalize_mode()

    trusted =
      config
      |> get_in(["approval", "trusted_assignees"])
      |> case do
        list when is_list(list) -> Enum.map(list, &to_string/1)
        _ -> []
      end

    %{mode: mode, trusted_assignees: MapSet.new(trusted)}
  end

  def config_from_map(_), do: %{mode: :off, trusted_assignees: MapSet.new()}

  @doc "Whether this task must wait for human approval before the first agent run."
  def required?(%{mode: :off}, _task, _agents), do: false

  def required?(%{mode: :all}, task, _agents) do
    gateable_status?(task)
  end

  def required?(%{mode: :untrusted, trusted_assignees: trusted}, task, agents) do
    gateable_status?(task) and not trusted_assignee?(task, agents, trusted)
  end

  @doc false
  def gateable_status?(%{status: "todo"}), do: true
  def gateable_status?(_), do: false

  defp trusted_assignee?(task, agents, trusted) do
    name = resolved_assignee(task, agents)
    MapSet.member?(trusted, name)
  end

  defp resolved_assignee(task, agents) do
    case task.assignee do
      name when is_binary(name) and name != "" ->
        if Map.has_key?(agents, name), do: name, else: fallback_assignee(task, agents)

      _ ->
        fallback_assignee(task, agents)
    end
  end

  defp fallback_assignee(task, agents) do
    ProfileRouter.assign("#{task.title} #{task.body}")
    |> then(fn name -> if Map.has_key?(agents, name), do: name, else: "default" end)
  end

  defp normalize_mode(nil), do: :off
  defp normalize_mode("off"), do: :off
  defp normalize_mode("all"), do: :all
  defp normalize_mode("untrusted"), do: :untrusted
  defp normalize_mode(:off), do: :off
  defp normalize_mode(:all), do: :all
  defp normalize_mode(:untrusted), do: :untrusted
  defp normalize_mode(_), do: :off

  ## Surface API (tracker-backed)

  def list_pending do
    {:ok, issues} = tracker().list_issues(%{}, status: @status_pending)
    issues
  end

  def approve(task_id) when is_binary(task_id) do
    case tracker().get_issue(%{}, task_id) do
      {:ok, %{status: @status_pending}} ->
        :ok = tracker().update_status(%{}, task_id, "todo")
        broadcast(:approved, task_id)
        :ok

      {:ok, %{status: other}} ->
        {:error, {:not_pending, other}}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  def reject(task_id, to_status \\ "failed") when is_binary(task_id) do
    if to_status in ["failed", "review"] do
      do_reject(task_id, to_status)
    else
      {:error, :invalid_status}
    end
  end

  defp do_reject(task_id, to_status) do
    case tracker().get_issue(%{}, task_id) do
      {:ok, %{status: @status_pending}} ->
        :ok = tracker().update_status(%{}, task_id, to_status)
        broadcast(:rejected, task_id)
        :ok

      {:ok, %{status: other}} ->
        {:error, {:not_pending, other}}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  @doc "User-facing flash message for approval API errors."
  def flash_error(reason)

  def flash_error(:not_found), do: "Task not found."
  def flash_error(:invalid_status), do: "Invalid reject status."
  def flash_error({:not_pending, status}), do: "Task is not pending approval (status: #{status})."
  def flash_error(other), do: "Could not update approval (#{inspect(other)})."

  defp broadcast(event, task_id) do
    Phoenix.PubSub.broadcast(Svarm.PubSub, "approvals", {event, task_id})
    Phoenix.PubSub.broadcast(Svarm.PubSub, Svarm.Events.topic(), {event, task_id})
  end
end
