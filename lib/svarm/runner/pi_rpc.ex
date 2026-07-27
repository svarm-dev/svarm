defmodule Svarm.Runner.PiRPC do
  @moduledoc """
  pi RPC runner adapter. Implements `Svarm.Runner` behaviour.

  Spawns pi in `--mode rpc` as a Port process, sends the task prompt via
  JSONL, streams output events to PubSub, and collects usage from
  `message_end` events.

  Protocol: https://pi.dev/docs/latest/rpc
  JSON events: https://pi.dev/docs/latest/json

  ## Completion signals

  The session ends when any of these occur:
    - `agent_settled` event (clean completion; then short grace for exit)
    - Port `exit_status` without settle (error if non-zero / unsettled)
    - wall-clock timeout → send `abort`, wait grace, then force-kill the OS tree
    - `extension_ui_request` → fail immediately (no mid-run Q&A yet)
    - `response` with `success: false` → fail (protocol / rejected command)

  `agent_end` fires per-run but does NOT end the session — pi may
  auto-retry or compact. Only `agent_settled` means "fully done."

  ## Timeouts vs orchestrator stall

  Default **wall-clock** run timeout is **45 minutes** (`@default_timeout_ms`).
  The receive loop uses a monotonic deadline so streaming output does **not**
  reset the timer. Override per call with `opts[:timeout_ms]` (tests).

  Orchestrator **stall** (`agent.stall_timeout_ms`, default also 45 min) is a
  separate safety net: it `Process.exit/2`s the worker. That closes the Port
  but does **not** run this module's `kill_tree/1` (grandchildren may need the
  kernel/reaper). Keep **PiRPC timeout ≤ stall** so abort→kill_tree runs first.

  ## pony tail: follow_up/steer not yet implemented.
  Add when Symphony §7.1 multi-turn continuation is prioritized.
  """
  @behaviour Svarm.Runner

  require Logger

  alias Svarm.Runner.LogFormat

  alias Svarm.{Events, Tracker, Workspace}
  alias Svarm.Workflow.Render

  # 45 min wall-clock — long enough for real coding agents; keep ≤ orchestrator stall.
  @default_timeout_ms 45 * 60_000
  @default_abort_grace_ms 5_000
  @default_settle_grace_ms 2_000
  # ponytail: drop lines over this; raise if real tool payloads exceed it.
  @max_line_bytes 1_000_000

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

  @doc false
  @spec take_lines(binary()) :: {binary(), [binary()]}
  def take_lines(buffer) when is_binary(buffer) do
    case :binary.split(buffer, "\n", [:global]) do
      [only] ->
        {only, []}

      parts ->
        rest = List.last(parts)
        lines = parts |> Enum.drop(-1) |> Enum.flat_map(&keep_jsonl_line/1)
        {rest, lines}
    end
  end

  defp keep_jsonl_line(""), do: []

  defp keep_jsonl_line(line) do
    if byte_size(line) > @max_line_bytes do
      Logger.warning("pi_rpc: dropping oversized JSONL line (#{byte_size(line)} bytes)")
      []
    else
      [line]
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

    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    abort_grace_ms = Keyword.get(opts, :abort_grace_ms, @default_abort_grace_ms)
    settle_grace_ms = Keyword.get(opts, :settle_grace_ms, @default_settle_grace_ms)
    executable = resolve_executable(opts, agent_config)

    case start_port(executable, build_args(agent_config), workspace_path, env) do
      {:ok, port} ->
        Logger.info("pi_rpc: started pi in #{workspace_path}")

        Events.broadcast_agent_line(
          task.id,
          "[pi_rpc] session started (#{agent_config[:model]})\n"
        )

        send_json(port, %{id: "prompt-1", type: "prompt", message: prompt})

        session0 = %{
          error: false,
          settled: false,
          reason: nil,
          exit_status: nil,
          tool_stdout_streamed: false
        }

        deadline = System.monotonic_time(:millisecond) + timeout_ms

        {log, usage, session} =
          drain_events(
            port,
            task.id,
            "",
            %{},
            session0,
            "",
            deadline,
            %{abort_grace_ms: abort_grace_ms, settle_grace_ms: settle_grace_ms}
          )

        ensure_dead(port)

        File.write!(log_path, log)
        record_usage(task, agent_config, usage, opts)

        finish(task, tracker, tracker_config, session)

      {:error, reason} ->
        Logger.error("pi_rpc: #{inspect(reason)}")
        board_error(task.id, reason)
        Events.broadcast_run_finished(task.id, -1)
        tracker.update_status(tracker_config, task.id, "failed")
        {:error, reason}
    end
  end

  defp finish(task, tracker, tracker_config, session) do
    exit_code = if session.error, do: 1, else: 0
    # Success → review (human PR gate). Agents never mark done/merge.
    status = if session.error, do: "failed", else: "review"

    Events.broadcast_run_finished(task.id, exit_code)
    tracker.update_status(tracker_config, task.id, status)

    if session.error do
      {:error, error_reason(session)}
    else
      :ok
    end
  end

  defp error_reason(%{reason: reason}) when not is_nil(reason), do: {:pi, reason}
  defp error_reason(_), do: {:pi, :agent_error}

  defp board_error(task_id, _reason) do
    Events.broadcast_agent_line(task_id, "\n[pi_rpc: pi not found on PATH]\n")
  end

  # -- port lifecycle --

  defp resolve_executable(opts, agent_config) do
    cond do
      path = opts[:executable] -> path
      path = agent_config[:executable] -> path
      true -> System.find_executable(agent_config[:command] || "pi")
    end
  end

  defp start_port(nil, _args, _cwd, _env), do: {:error, {:pi, :not_on_path}}

  defp start_port(executable, args, cwd, env) do
    if File.regular?(executable) do
      # Raw binary (not :line) so we own JSONL framing across partial chunks.
      port_opts =
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:args, args}, {:cd, cwd}]
        |> Svarm.Runner.maybe_add_env(env)

      port = Port.open({:spawn_executable, executable}, port_opts)
      {:ok, port}
    else
      {:error, {:pi, :not_on_path}}
    end
  end

  defp ensure_dead(port) do
    info = Port.info(port)
    os_pid = info && Keyword.get(info, :os_pid)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    if is_integer(os_pid), do: force_kill(os_pid)
    :ok
  end

  defp force_kill(os_pid) when is_integer(os_pid) do
    # Descendants first (e.g. sleep/node under the shell), then the port pid.
    kill_tree(os_pid)
    :ok
  end

  defp kill_tree(os_pid) when is_integer(os_pid) do
    # Docker slim images often lack pgrep (procps). Never raise here — a cleanup
    # failure must not crash the worker after a successful run.
    case System.find_executable("pgrep") do
      nil ->
        :ok

      pgrep ->
        case System.cmd(pgrep, ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true) do
          {out, 0} -> Enum.each(String.split(out), &kill_parsed_child/1)
          _ -> :ok
        end
    end

    case System.find_executable("kill") do
      nil -> :ok
      kill -> _ = System.cmd(kill, ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end

    :ok
  end

  defp kill_parsed_child(child) do
    case Integer.parse(child) do
      {cid, ""} -> kill_tree(cid)
      _ -> :ok
    end
  end

  # -- event loop (wall-clock deadlines) --

  defp remaining_ms(deadline) do
    max(0, deadline - System.monotonic_time(:millisecond))
  end

  defp drain_events(port, task_id, log, usage, session, buffer, deadline, grace) do
    receive do
      {^port, {:data, data}} ->
        binary = normalize_data(data)
        {buffer, lines} = take_lines(buffer <> binary)
        {log, usage, session} = process_lines(lines, task_id, log, usage, session)

        if session.settled do
          settle_deadline = System.monotonic_time(:millisecond) + grace.settle_grace_ms
          drain_after_settle(port, task_id, log, usage, session, buffer, settle_deadline)
        else
          drain_events(port, task_id, log, usage, session, buffer, deadline, grace)
        end

      {^port, {:exit_status, status}} ->
        handle_exit(task_id, log, usage, session, status)
    after
      remaining_ms(deadline) ->
        send_json(port, %{id: "abort-1", type: "abort"})
        Events.broadcast_agent_line(task_id, "\n[pi_rpc: timeout, aborting]\n")

        session = %{session | error: true, reason: session.reason || :timeout}
        abort_deadline = System.monotonic_time(:millisecond) + grace.abort_grace_ms

        {log, usage, session, _buffer} =
          wait_abort(port, task_id, log, usage, session, buffer, abort_deadline)

        {log, usage, %{session | settled: true}}
    end
  end

  defp drain_after_settle(port, task_id, log, usage, session, buffer, deadline) do
    receive do
      {^port, {:data, data}} ->
        binary = normalize_data(data)
        {buffer, lines} = take_lines(buffer <> binary)
        {log, usage, session} = process_lines(lines, task_id, log, usage, session)
        drain_after_settle(port, task_id, log, usage, session, buffer, deadline)

      {^port, {:exit_status, status}} ->
        {log, usage, %{session | exit_status: status, settled: true}}
    after
      remaining_ms(deadline) ->
        {log, usage, %{session | settled: true}}
    end
  end

  defp wait_abort(port, task_id, log, usage, session, buffer, deadline) do
    receive do
      {^port, {:data, data}} ->
        binary = normalize_data(data)
        {buffer, lines} = take_lines(buffer <> binary)
        {log, usage, session} = process_lines(lines, task_id, log, usage, session)

        if session.settled do
          {log, usage, session, buffer}
        else
          wait_abort(port, task_id, log, usage, session, buffer, deadline)
        end

      {^port, {:exit_status, status}} ->
        {log, usage, %{session | exit_status: status, settled: true}, buffer}
    after
      remaining_ms(deadline) ->
        Events.broadcast_agent_line(task_id, "\n[pi_rpc: abort grace elapsed, killing process]\n")
        {log, usage, %{session | settled: true}, buffer}
    end
  end

  defp handle_exit(task_id, log, usage, session, status) do
    session = %{session | exit_status: status}

    cond do
      session.settled ->
        {log, usage, session}

      status == 0 ->
        # Clean exit without settle — treat as incomplete protocol.
        Events.broadcast_agent_line(
          task_id,
          "\n[pi_rpc: process exited 0 without agent_settled]\n"
        )

        {log, usage, %{session | error: true, settled: true, reason: :protocol}}

      true ->
        Events.broadcast_agent_line(task_id, "\n[pi_rpc: process exited #{status}]\n")
        {log, usage, %{session | error: true, settled: true, reason: {:exit, status}}}
    end
  end

  defp normalize_data({:eol, b}) when is_binary(b), do: b <> "\n"
  defp normalize_data({:noeol, b}) when is_binary(b), do: b
  defp normalize_data(b) when is_binary(b), do: b
  defp normalize_data(_), do: ""

  defp process_lines([], _task_id, log, usage, session), do: {log, usage, session}

  defp process_lines([line | rest], task_id, log, usage, session) do
    {log, usage, session} =
      case safe_decode(line) do
        {:ok, event} -> handle_event(event, task_id, log, usage, session)
        :error -> {log <> line <> "\n", usage, session}
      end

    if session.settled do
      {log, usage, session}
    else
      process_lines(rest, task_id, log, usage, session)
    end
  end

  defp safe_decode(line) do
    case Jason.decode(line) do
      {:ok, event} -> {:ok, event}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  # -- event handlers --

  defp handle_event(%{"type" => "agent_settled"}, _task_id, log, usage, session) do
    {log, usage, %{session | settled: true}}
  end

  defp handle_event(
         %{"type" => "response", "success" => false} = event,
         task_id,
         log,
         usage,
         session
       ) do
    err = event["error"] || "command rejected"

    Events.broadcast_agent_line(
      task_id,
      "\n[pi_rpc: protocol error: #{inspect(err)}]\n"
    )

    {log, usage, %{session | error: true, settled: true, reason: :protocol}}
  end

  defp handle_event(%{"type" => "response"}, _task_id, log, usage, session) do
    {log, usage, session}
  end

  defp handle_event(%{"type" => "extension_ui_request"} = event, task_id, log, usage, session) do
    kind = event["requestType"] || event["request_type"] || "unknown"

    Events.broadcast_agent_line(
      task_id,
      "\n[pi_rpc: unsupported UI request (#{kind}) — failing run]\n"
    )

    {log, usage, %{session | error: true, settled: true, reason: :ui_request}}
  end

  defp handle_event(%{"type" => "agent_end"} = event, task_id, log, usage, session) do
    # agent_end fires per-run but doesn't mean the session is done.
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
    {log, merge_message_usage(usage, msg), session}
  end

  defp handle_event(%{"type" => "tool_execution_start"} = event, task_id, log, usage, session) do
    name = event["toolName"] || "tool"
    args = event["args"] || event["input"] || event["arguments"]
    Events.broadcast_agent_line(task_id, LogFormat.tool_start(name, args))
    {log, usage, %{session | tool_stdout_streamed: false}}
  end

  defp handle_event(%{"type" => "tool_execution_update"} = event, task_id, log, usage, session) do
    session =
      case broadcast_tool_text(task_id, event["partialResult"]) do
        :ok -> session
        :streamed -> %{session | tool_stdout_streamed: true}
      end

    {log, usage, session}
  end

  defp handle_event(%{"type" => "tool_execution_end"} = event, task_id, log, usage, session) do
    name = event["toolName"] || "tool"

    cond do
      event["isError"] ->
        Events.broadcast_agent_line(task_id, LogFormat.tool_fail(name, event["result"]))

      session[:tool_stdout_streamed] ->
        :ok

      true ->
        # Tools that only report on end (no partial updates).
        _ = broadcast_tool_text(task_id, event["result"] || event["partialResult"])
    end

    {log, usage, %{session | tool_stdout_streamed: false}}
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
      {log, usage, %{session | error: true, reason: :agent_error}}
    else
      {log, usage, session}
    end
  end

  defp handle_event(%{"type" => "extension_error"} = event, task_id, log, usage, session) do
    Logger.warning("pi_rpc: extension error: #{inspect(event["error"])}")

    Events.broadcast_agent_line(
      task_id,
      "\n[pi_rpc: extension error: #{inspect(event["error"])}]\n"
    )

    {log, usage, %{session | error: true, reason: :protocol}}
  end

  defp handle_event(_other, _task_id, log, usage, session), do: {log, usage, session}

  # -- helpers --

  defp merge_message_usage(usage, msg) do
    msg_usage = msg["usage"] || %{}

    usage
    |> Map.update(:prompt_tokens, msg_usage["input"] || 0, &(&1 + (msg_usage["input"] || 0)))
    |> Map.update(
      :completion_tokens,
      msg_usage["output"] || 0,
      &(&1 + (msg_usage["output"] || 0))
    )
    |> maybe_add_provider_cost(extract_usage_cost(msg, msg_usage))
  end

  defp extract_usage_cost(msg, msg_usage) do
    get_in(msg_usage, ["cost", "total"]) ||
      get_in(msg_usage, ["cost", "total_cost"]) ||
      numeric_cost(msg_usage["cost"]) ||
      get_in(msg, ["cost", "total"])
  end

  defp numeric_cost(c) when is_number(c), do: c
  defp numeric_cost(_), do: nil

  defp maybe_add_provider_cost(usage, cost) when is_number(cost) do
    Map.update(usage, :provider_cost, cost, &(&1 + cost))
  end

  defp maybe_add_provider_cost(usage, _), do: usage

  defp broadcast_tool_text(task_id, payload) do
    case LogFormat.unwrap(payload) do
      nil ->
        :ok

      text ->
        line = if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
        Events.broadcast_agent_line(task_id, line)
        :streamed
    end
  end

  defp build_args(agent_config) do
    args = ["--mode", "rpc", "--no-session"]
    args = if provider = agent_config[:provider], do: args ++ ["--provider", provider], else: args
    args = if model = agent_config[:model], do: args ++ ["--model", model], else: args

    if name = agent_config[:display_name], do: args ++ ["--name", name], else: args
  end

  defp send_json(port, map) do
    Port.command(port, Jason.encode!(map) <> "\n")
  rescue
    ArgumentError -> :ok
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
