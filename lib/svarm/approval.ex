defmodule Svarm.Approval do
  @moduledoc """
  Human-in-the-loop gate before agent execution.

  Trust is workflow-driven: `approval.mode` and `approval.trusted_assignees`.
  Tasks held in kanban status `pending_approval` until approved.

  Surface API (`list_pending/0`, `approve/1`, `reject/2`) uses the **active**
  tracker adapter + config — same settings/workflow resolve path as the
  orchestrator and board — not a hardcoded Local adapter.
  """

  alias Svarm.{Budget, ProfileRouter, Tracker}

  @status_pending "pending_approval"
  @tracker_override {__MODULE__, :tracker_override}

  def pending_status, do: @status_pending

  @doc """
  Returns the active tracker adapter (same resolve as orchestrator/board).
  """
  def tracker do
    {adapter, _config} = resolve_tracker()
    adapter
  end

  @doc """
  Returns the active tracker config (workflow + Settings overlay).
  """
  def tracker_config do
    {_adapter, config} = resolve_tracker()
    config
  end

  @doc false
  def __override_tracker__(adapter, config) when is_atom(adapter) and is_map(config) do
    Process.put(@tracker_override, {adapter, config})
  end

  @doc false
  def __clear_tracker_override__ do
    Process.delete(@tracker_override)
  end

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
    {adapter, config} = resolve_tracker()
    {:ok, issues} = adapter.list_issues(config, status: @status_pending)
    Enum.reject(issues, &Budget.held?(&1.id))
  end

  def approve(task_id) when is_binary(task_id) do
    {adapter, config} = resolve_tracker()
    do_approve(adapter, config, task_id)
  end

  defp do_approve(adapter, config, task_id) do
    case adapter.get_issue(config, task_id) do
      {:ok, %{status: @status_pending}} ->
        if Budget.held?(task_id) do
          Budget.approve_overage(task_id)
        else
          :ok = adapter.update_status(config, task_id, "todo")
          # One-shot: next poll may dispatch without re-entering pending_approval
          Svarm.Orchestrator.mark_approved(task_id)
          broadcast(:approved, task_id)
          :ok
        end

      {:ok, %{status: other}} ->
        {:error, {:not_pending, other}}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  def reject(task_id, to_status \\ "failed") when is_binary(task_id) do
    if to_status in ["failed", "review"] do
      {adapter, config} = resolve_tracker()
      do_reject(adapter, config, task_id, to_status)
    else
      {:error, :invalid_status}
    end
  end

  defp do_reject(adapter, config, task_id, to_status) do
    case adapter.get_issue(config, task_id) do
      {:ok, %{status: @status_pending}} ->
        if Budget.held?(task_id), do: Budget.clear_hold(task_id)
        :ok = adapter.update_status(config, task_id, to_status)
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

  # Same settings/workflow resolve path as Board / Orchestrator.
  defp resolve_tracker do
    case Process.get(@tracker_override) do
      {adapter, config} when is_atom(adapter) and is_map(config) ->
        {adapter, config}

      _ ->
        Tracker.Resolve.adapter_and_config()
    end
  end
end
