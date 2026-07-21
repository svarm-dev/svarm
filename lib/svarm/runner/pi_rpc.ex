defmodule Svarm.Runner.PiRPC do
  @moduledoc """
  pi RPC runner adapter. Implements `Svarm.Runner` behaviour.

  Spawns pi in `--mode rpc` as a persistent Port process, sends the task
  prompt via JSONL, streams output events to PubSub, and collects real
  usage data from the agent's message_end events.

  Protocol: https://pi.dev/docs/latest/rpc
  JSON events: https://pi.dev/docs/latest/json

  ## Completion signals

  The session ends when any of these occur:
    - `agent_settled` event (clean completion)
    - Port exit_status (pi process died/crashed)
    - 1-hour timeout (send abort, then close)

  `agent_end` fires per-run but does NOT end the session — pi may
  auto-retry or compact. Only `agent_settled` means "fully done."

  ## pony tail: follow_up/steer not yet implemented.
  Add when Symphony §7.1 multi-turn continuation is prioritized.
  """
  @behaviour Svarm.Runner

  require Logger

  alias Svarm.{Events, Tracker, Workspace}
  alias Svarm.Workflow.Render

  @timeout_ms 300_000

  @impl true
  def run(task, agent_config, opts) do
    Logger.info(
      "pi_rpc: dispatching #{task.id} with adapter=#{agent_config[:adapter]} model=#{agent_config[:model]}"
    )

    workspace_root = Keyword.get(opts, :workspace_root, Workspace.default_root())
    tracker = Keyword.get(opts, :tracker, Tracker.Local)
    tracker_config = Keyword.get(opts, :tracker_config, %{})

    workspace_key = Workspace.key_for_issue(task)
    {workspace_path, _created_now} = Workspace.ensure(workspace_key, workspace_root)

    attempt = (task.attempts || 0) + 1
    log_path = Path.join(workspace_path, "run.log")

    case Render.render_prompt(task, attempt) do
      {:ok, prompt} ->
        do_run_pi(
          task,
          agent_config,
          tracker,
          tracker_config,
          workspace_path,
          prompt,
          log_path,
          opts
        )

      {:error, reason} ->
        Logger.error("prompt render failed for task #{task.id}: #{inspect(reason)}")
        tracker.update_status(tracker_config, task.id, "failed")
        {:error, {:prompt_render_error, reason}}
    end
  end

  defp do_run_pi(
         task,
         agent_config,
         tracker,
         tracker_config,
         workspace_path,
         prompt,
         log_path,
         opts
       ) do
    meta =
      Svarm.AgentRegistry.run_started_meta(task, agent_config)
      |> Map.merge(%{
        workspace_path: workspace_path,
        started_mono_ms: System.monotonic_time(:millisecond)
      })

    Events.broadcast_run_started(task.id, meta)

    env =
      (agent_config[:env] || %{})
      |> Svarm.Runner.with_github_token(tracker_config)

    case start_port(build_args(agent_config), workspace_path, env) do
      {:ok, port} ->
        Logger.info("pi_rpc: started pi in #{workspace_path}")

        Events.broadcast_agent_line(
          task.id,
          "[pi_rpc] session started (#{agent_config[:model]})\n"
        )

        send_json(port, %{id: "prompt-1", type: "prompt", message: prompt})

        {log, usage, session} =
          drain_events(port, task.id, "", %{}, %{error: false, settled: false})

        Port.close(port)
        File.write!(log_path, log)

        record_usage(task, agent_config, usage, opts)

        exit_code = if session.error, do: 1, else: 0
        # Success → review (human PR gate). Agents never mark done/merge.
        status = if session.error, do: "failed", else: "review"

        Events.broadcast_run_finished(task.id, exit_code)
        tracker.update_status(tracker_config, task.id, status)

        if session.error do
          {:error, {:agent_error, "pi session ended with errors"}}
        else
          :ok
        end

      {:error, reason} ->
        Logger.error("pi_rpc: #{inspect(reason)}")
        Events.broadcast_run_finished(task.id, -1)
        tracker.update_status(tracker_config, task.id, "failed")
        {:error, reason}
    end
  end

  # -- port lifecycle --

  defp start_port(args, cwd, env) do
    executable = System.find_executable("pi")

    if is_nil(executable) do
      {:error, "pi not found on PATH"}
    else
      port_opts =
        [:binary, :exit_status, :use_stdio, {:args, args}, {:cd, cwd}, {:line, 65_000}]
        |> Svarm.Runner.maybe_add_env(env)

      port = Port.open({:spawn_executable, executable}, port_opts)
      {:ok, port}
    end
  end

  # -- event loop --

  defp process_port_data(data, port, task_id, log, usage, session) do
    # Port with :use_stdio + :line wraps eol inside :data: {:data, {:eol, binary}}
    binary =
      case data do
        {:eol, b} -> b
        b when is_binary(b) -> b
      end

    lines = String.split(binary, "\n", trim: true)
    {log, usage, session} = process_lines(lines, task_id, log, usage, session)

    if session.settled do
      {log, usage, session}
    else
      drain_events(port, task_id, log, usage, session)
    end
  end

  defp drain_events(port, task_id, log, usage, session) do
    receive do
      {^port, {:data, data}} ->
        process_port_data(data, port, task_id, log, usage, session)

      {^port, {:exit_status, status}} ->
        # pi process died — if we didn't get agent_settled, that's an error
        if status != 0 and not session.settled do
          Events.broadcast_agent_line(task_id, "\n[pi_rpc: process exited #{status}]\n")
          {log, usage, %{session | error: true, settled: true}}
        else
          {log, usage, session}
        end
    after
      @timeout_ms ->
        send_json(port, %{id: "abort-1", type: "abort"})
        Events.broadcast_agent_line(task_id, "\n[pi_rpc: timeout, aborting]\n")
        {log, usage, %{session | error: true, settled: true}}
    end
  end

  defp process_lines([], _task_id, log, usage, session), do: {log, usage, session}

  defp process_lines([line | rest], task_id, log, usage, session) do
    {log, usage, session} =
      case Jason.decode(line) do
        {:ok, event} -> handle_event(event, task_id, log, usage, session)
        _ -> {log <> line <> "\n", usage, session}
      end

    if session.settled do
      {log, usage, session}
    else
      process_lines(rest, task_id, log, usage, session)
    end
  end

  # -- event handlers —

  defp handle_event(%{"type" => "agent_settled"}, _task_id, log, usage, session) do
    {log, usage, %{session | settled: true}}
  end

  defp handle_event(%{"type" => "agent_end"} = event, task_id, log, usage, session) do
    # agent_end fires per-run but doesn't mean the session is done.
    # pi may auto-retry or compact. We keep draining.
    msgs = length(event["messages"] || [])
    Events.broadcast_agent_line(task_id, "\n[pi_rpc: run complete, #{msgs} messages]\n")
    {log, usage, session}
  end

  defp handle_event(%{"type" => "message_update"} = event, task_id, log, usage, session) do
    delta = event["assistantMessageEvent"] || %{}

    case delta["type"] do
      "text_delta" ->
        text = delta["delta"] || ""
        Events.broadcast_agent_line(task_id, text)
        {log <> text, usage, session}

      "thinking_delta" ->
        {log, usage, session}

      _ ->
        {log, usage, session}
    end
  end

  defp handle_event(%{"type" => "message_end"} = event, _task_id, log, usage, session) do
    msg = event["message"] || %{}
    msg_usage = msg["usage"] || %{}
    cost = get_in(msg_usage, ["cost", "total"])

    usage =
      usage
      |> Map.update(:prompt_tokens, msg_usage["input"] || 0, &(&1 + (msg_usage["input"] || 0)))
      |> Map.update(
        :completion_tokens,
        msg_usage["output"] || 0,
        &(&1 + (msg_usage["output"] || 0))
      )

    # Accumulate provider-reported cost for reconciliation
    usage =
      if is_number(cost) do
        Map.update(usage, :provider_cost, cost, &(&1 + cost))
      else
        usage
      end

    {log, usage, session}
  end

  defp handle_event(%{"type" => "tool_execution_update"} = event, task_id, log, usage, session) do
    partial = event["partialResult"]

    cond do
      is_binary(partial) -> Events.broadcast_agent_line(task_id, partial)
      is_map(partial) -> Events.broadcast_agent_line(task_id, inspect(partial) <> "\n")
      is_list(partial) -> Events.broadcast_agent_line(task_id, inspect(partial) <> "\n")
      true -> :ok
    end

    {log, usage, session}
  end

  defp handle_event(%{"type" => "tool_execution_end"} = event, task_id, log, usage, session) do
    if event["isError"] do
      Events.broadcast_agent_line(
        task_id,
        "\n[pi_rpc: tool #{event["toolName"]} failed: #{inspect(event["result"])}]\n"
      )
    end

    {log, usage, session}
  end

  defp handle_event(%{"type" => "compaction_end"} = event, task_id, log, usage, session) do
    tokens = get_in(event, ["result", "estimatedTokensAfter"]) || "?"
    aborted = event["aborted"] || false
    will_retry = event["willRetry"] || false

    msg =
      cond do
        aborted -> "\n[pi_rpc: compaction aborted]\n"
        will_retry -> "\n[pi_rpc: context compacted, #{tokens} tokens, retrying]\n"
        true -> "\n[pi_rpc: context compacted, #{tokens} tokens]\n"
      end

    Events.broadcast_agent_line(task_id, msg)
    {log, usage, session}
  end

  defp handle_event(%{"type" => "auto_retry_start"} = event, task_id, log, usage, session) do
    Events.broadcast_agent_line(
      task_id,
      "\n[pi_rpc: auto-retry #{event["attempt"]}/#{event["maxAttempts"]} — #{event["errorMessage"]}]\n"
    )

    {log, usage, session}
  end

  defp handle_event(%{"type" => "auto_retry_end"} = event, task_id, log, usage, session) do
    if event["success"] == false do
      final = event["finalError"] || "unknown error"
      Events.broadcast_agent_line(task_id, "\n[pi_rpc: retry exhausted: #{final}]\n")
      {log, usage, %{session | error: true}}
    else
      {log, usage, session}
    end
  end

  defp handle_event(%{"type" => "extension_error"} = event, _task_id, log, usage, session) do
    Logger.warning("pi_rpc: extension error: #{inspect(event["error"])}")
    {log, usage, %{session | error: true}}
  end

  defp handle_event(_other, _task_id, log, usage, session), do: {log, usage, session}

  # -- helpers --

  defp build_args(agent_config) do
    args = ["--mode", "rpc", "--no-session"]
    args = if provider = agent_config[:provider], do: args ++ ["--provider", provider], else: args
    args = if model = agent_config[:model], do: args ++ ["--model", model], else: args

    if name = agent_config[:display_name], do: args ++ ["--name", name], else: args
  end

  defp send_json(port, map) do
    Port.command(port, Jason.encode!(map) <> "\n")
  end

  defp record_usage(task, agent_config, usage, opts) do
    run_id = opts[:run_id] || default_run_id()

    Svarm.Usage.append(%{
      run_id: run_id,
      task_id: task.id,
      tenant: task.tenant,
      source: "worker",
      provider: agent_config[:provider] || "unknown",
      model_id: agent_config[:model] || "unknown",
      prompt_tokens: usage[:prompt_tokens],
      completion_tokens: usage[:completion_tokens],
      provider_cost_usd: usage[:provider_cost],
      estimated: is_nil(usage[:prompt_tokens])
    })
  end

  defp default_run_id, do: "run_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
