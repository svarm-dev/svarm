defmodule Svarm.Orchestrator.RunExit do
  @moduledoc """
  Worker exit handling, force-terminal status, post-run summary, and retries.

  Normal exit → completed (force `review` if the tracker is still active).
  Crash / error → backoff retry. Exhausted retries escalate to `failed` and
  post a run summary. PR URLs are parsed from the run log into Coordination
  when the tracker owner/repo is known.
  """

  require Logger

  alias Svarm.{Coordination, Usage}
  alias Svarm.Orchestrator.Dispatch

  @base_backoff_ms 10_000
  @continuation_retry_ms 1_000
  # Force-terminal status patch after ok exit: retry without blocking the GenServer.
  @force_terminal_max_attempts 3
  @force_terminal_backoff_ms 400

  @doc false
  def handle(state, entry, task_id, result) do
    state =
      state
      |> Map.update!(:claimed, &MapSet.delete(&1, task_id))
      |> Map.update!(:last_run_entries, &Map.put(&1, task_id, entry))

    handle_result(state, task_id, result)
  end

  @doc false
  def do_retry(state, entry, task_id) do
    case state.tracker.get_issue(state.tracker_config, task_id) do
      {:ok, task} ->
        if task.status in state.terminal_states do
          %{state | claimed: MapSet.delete(state.claimed, task_id)}
        else
          retry_or_spawn(state, task, task_id, entry)
        end

      {:error, _} ->
        Logger.info("retry: task #{task_id} gone, releasing claim")
        %{state | claimed: MapSet.delete(state.claimed, task_id)}
    end
  end

  @doc false
  def force_terminal(state, task_id, status, attempt) do
    state.tracker.update_status(state.tracker_config, task_id, status)

    case force_terminal_check(state, task_id) do
      :ok ->
        :ok

      :retry ->
        schedule_force_terminal_retry(task_id, status, attempt)
    end
  end

  @doc false
  def post_run_summary(state, task_id, result) do
    maybe_capture_pr(state, task_id)

    entry = state.last_run_entries[task_id]
    if entry, do: build_and_post(state, task_id, result, entry)
    :ok
  end

  @doc false
  def schedule_retry(state, nil, _reason), do: state

  def schedule_retry(state, task, reason) do
    task_id = task.id
    next = (task.attempts || 0) + 1
    state.tracker.update_attempts(state.tracker_config, task_id, next)

    if next > state.max_retries do
      Logger.error("task #{task_id} exhausted #{state.max_retries} retries → human escalation")
      state.tracker.update_status(state.tracker_config, task_id, "failed")
      post_run_summary(state, task_id, {:error, reason})
      %{state | claimed: MapSet.delete(state.claimed, task_id)}
    else
      delay = backoff(state, next)
      Logger.info("task #{task_id} retry #{next} in #{delay}ms (#{inspect(reason)})")
      timer = Process.send_after(self(), {:retry, task_id}, delay)

      entry = %{
        attempt: next,
        identifier: task_id,
        due_at_mono: System.monotonic_time(:millisecond) + delay,
        timer: timer
      }

      %{state | retry_attempts: Map.put(state.retry_attempts, task_id, entry)}
    end
  end

  defp retry_or_spawn(state, task, task_id, entry) do
    cond do
      not Dispatch.valid_preflight?(state) ->
        # Same as no-slot: keep the retry so a later valid reload can resume.
        # Tick dispatch is already gated; retries used to skip that check.
        Logger.debug("retry: #{task_id} deferred; workflow preflight failed")
        defer_retry(state, task_id, entry)

      Dispatch.slots_available?(state) ->
        # Same hard caps as first dispatch — retries are still new agent processes
        Dispatch.maybe_budget_or_spawn(state, task)

      true ->
        defer_retry(state, task_id, entry)
    end
  end

  defp defer_retry(state, task_id, entry) do
    timer = Process.send_after(self(), {:retry, task_id}, @continuation_retry_ms)
    retry = Map.put(entry || %{}, :timer, timer)
    %{state | retry_attempts: Map.put(state.retry_attempts, task_id, retry)}
  end

  defp handle_result(state, task_id, :ok) do
    case state.tracker.get_issue(state.tracker_config, task_id) do
      {:ok, task} ->
        if task.status in state.terminal_states do
          Logger.info("task #{task_id} succeeded")
          post_run_summary(state, task_id, :ok)
          %{state | completed: MapSet.put(state.completed, task_id)}
        else
          # Runner reported success (exit 0). Do not re-spawn (burns tokens /
          # rate-limits). Force terminal review; retry status patch so GitHub
          # label sticks across process restarts when possible.
          # Retries use send_after — never Process.sleep on this GenServer.
          Logger.warning("task #{task_id} exited ok but status=#{task.status}; forcing review")

          force_terminal(state, task_id, "review", 1)
          post_run_summary(state, task_id, :ok)
          %{state | completed: MapSet.put(state.completed, task_id)}
        end

      {:error, _} ->
        Logger.info("task #{task_id} succeeded (issue gone from tracker)")
        post_run_summary(state, task_id, :ok)
        %{state | completed: MapSet.put(state.completed, task_id)}
    end
  end

  defp handle_result(state, task_id, {:error, reason}) do
    task =
      case state.tracker.get_issue(state.tracker_config, task_id) do
        {:ok, t} -> t
        _ -> nil
      end

    schedule_retry(%{state | completed: MapSet.delete(state.completed, task_id)}, task, reason)
  end

  defp force_terminal_check(state, task_id) do
    case state.tracker.get_issue(state.tracker_config, task_id) do
      {:ok, t} ->
        if t.status in state.terminal_states, do: :ok, else: :retry

      _ ->
        :retry
    end
  end

  defp schedule_force_terminal_retry(task_id, status, attempt)
       when attempt < @force_terminal_max_attempts do
    delay = @force_terminal_backoff_ms * attempt
    Process.send_after(self(), {:force_terminal_retry, task_id, status, attempt + 1}, delay)
    :ok
  end

  defp schedule_force_terminal_retry(task_id, _status, attempt) do
    Logger.warning(
      "task #{task_id}: status still non-terminal after #{attempt} tries (session skip via completed)"
    )

    :ok
  end

  # Best-effort: parse PR URL from run log (agent stdout) into Coordination.
  # Bound to tracker owner/repo when known (confused-deputy guard).
  defp maybe_capture_pr(state, task_id) when is_binary(task_id) do
    log = Svarm.RunLog.get(task_id)
    opts = tracker_repo_opts(state.tracker_config)

    case Coordination.extract_pr_url(log) do
      url when is_binary(url) ->
        case Coordination.record_pr(task_id, url, opts) do
          {:ok, _} ->
            Logger.info("coordination: recorded PR for #{task_id}")

          {:error, :repo_mismatch} ->
            Logger.warning(
              "coordination: ignored PR URL for #{task_id} (owner/repo mismatch tracker)"
            )

          {:error, reason} ->
            Logger.debug("coordination: PR capture failed for #{task_id}: #{inspect(reason)}")
        end

      nil ->
        :ok
    end
  end

  defp tracker_repo_opts(%{owner: owner, repo: repo})
       when is_binary(owner) and is_binary(repo),
       do: [owner: owner, repo: repo]

  defp tracker_repo_opts(_), do: []

  defp build_and_post(state, task_id, result, entry) do
    task = entry.task
    assignee = task.assignee || "default"
    agent = Map.get(state.agents, assignee, %{})
    pr_url = coordination_pr_url(task_id)

    cost = Usage.task_cost(task_id)

    summary = %{
      run_id: entry[:run_id],
      task_id: task_id,
      task: task,
      result: result,
      duration_ms: System.monotonic_time(:millisecond) - entry.started_mono_ms,
      agent_name: agent[:display_name] || assignee,
      agent_role: blank_to_nil(agent[:role]),
      adapter: agent[:adapter],
      harness: harness_label(agent),
      model: agent[:model],
      provider: agent[:provider],
      cost: cost,
      total_tokens: (cost.prompt_tokens || 0) + (cost.completion_tokens || 0),
      branch: nil,
      pr_url: pr_url,
      exit_code: exit_code_from_result(result)
    }

    state.tracker.post_run_summary(state.tracker_config, task_id, summary)
  end

  defp coordination_pr_url(task_id) do
    case Coordination.get(task_id) do
      %{pr_url: url} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp harness_label(%{adapter: "pi_rpc"}), do: "Pi"

  defp harness_label(%{adapter: "cli", command: command}) when is_binary(command) do
    cond do
      String.contains?(command, "claude") -> "Claude Code"
      String.contains?(command, "codex") -> "Codex CLI"
      true -> "CLI Agent"
    end
  end

  defp harness_label(_), do: "Unknown"

  defp exit_code_from_result(:ok), do: 0
  defp exit_code_from_result({:error, _}), do: 1

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  defp backoff(state, attempt) do
    (@base_backoff_ms * trunc(:math.pow(2, attempt - 1)))
    |> min(state.max_retry_backoff_ms)
  end
end
