defmodule Svarm.Events do
  @moduledoc """
  PubSub topics for the LiveView board.

  Agent output and run markers are persisted once here (`RunLog.append`) then
  broadcast so late join works with zero open boards and N boards never
  double-write.

  Live path emits `{:stream_event, task_id, event}` (`Svarm.StreamEvent`).
  RunLog stores the text projection only (no kind column). `{:agent_line, ...}`
  remains as a compatibility broadcast; BoardLive renders `:stream_event`.

  Redaction: PubSub payloads go through `Redact.map/1`. Persist-path scrubbing
  is `RunLog.append/2` only — fail-closed if a caller skips Events.
  `persist_agent_line/2` must not call `Redact.text/1` again.
  """
  @topic "board"

  alias Svarm.{Redact, StreamEvent}

  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(Svarm.PubSub, @topic)
  end

  def broadcast_task_updated(task) when is_map(task) do
    id = Map.get(task, :id)
    status = Map.get(task, :status)

    if is_binary(id) and is_binary(status) do
      persist_agent_line(id, "[board] status → #{status}\n")
    end

    broadcast({:task_updated, task})
  end

  def broadcast_tasks_snapshot(tasks) when is_list(tasks) do
    broadcast({:tasks_snapshot, tasks})
  end

  def broadcast_orchestrator_status(status) when is_map(status) do
    broadcast({:orchestrator_status, status})
  end

  @doc """
  Redact, persist a text projection, then broadcast `{:stream_event, task_id, event}`.

  When the projection is non-empty, also broadcasts the compatibility tuple
  `{:agent_line, task_id, text}`. Pass `agent_line: false` for run markers that
  already have `{:run_started, ...}` / `{:run_finished, ...}`.
  """
  def broadcast_stream_event(task_id, event, opts \\ [])

  def broadcast_stream_event(task_id, %{kind: kind, payload: payload}, opts)
      when is_binary(task_id) and is_map(payload) do
    case StreamEvent.parse_kind(kind) do
      {:ok, kind} ->
        event = StreamEvent.new(kind, Redact.map(payload))
        text = StreamEvent.to_text(event)
        text = if text != "", do: persist_agent_line(task_id, text), else: ""
        broadcast({:stream_event, task_id, event})

        if text != "" and Keyword.get(opts, :agent_line, true) do
          broadcast({:agent_line, task_id, text})
        end

        :ok

      :error ->
        :ok
    end
  end

  @doc """
  Redact, persist to `RunLog`, then broadcast `{:agent_line, task_id, line}`.

  Implemented as a `:text` stream event. Single writer — callers must not also
  call `RunLog.append/2`.
  """
  def broadcast_agent_line(task_id, line) when is_binary(task_id) and is_binary(line) do
    broadcast_stream_event(task_id, StreamEvent.new(:text, %{text: line}))
  end

  @doc """
  Persist a transcript chunk once. Used by broadcast helpers.

  Does not redact — `RunLog.append/2` is the single persist-path redact so
  callers that skip Events stay fail-closed. Prefer
  `broadcast_stream_event/2` / `broadcast_agent_line/2` /
  `broadcast_run_started/2` / `broadcast_run_finished/2` so PubSub and RunLog
  stay in lockstep.
  """
  def persist_agent_line(task_id, line) when is_binary(task_id) and is_binary(line) do
    Svarm.RunLog.append(task_id, line)
    line
  end

  @doc """
  Persist the run-started banner once, then broadcast `{:run_started, task_id, meta}`
  and a `:run_marker` stream event.
  """
  def broadcast_run_started(task_id, meta) when is_map(meta) do
    event = StreamEvent.new(:run_marker, %{phase: :started, label: run_started_label(meta)})
    broadcast_stream_event(task_id, event, agent_line: false)
    broadcast({:run_started, task_id, meta})
  end

  @doc """
  Persist the run-finished banner once, flush the run log, then broadcast
  `{:run_finished, task_id, exit_code}` and a `:run_marker` stream event.
  """
  def broadcast_run_finished(task_id, exit_code) when is_integer(exit_code) do
    event = StreamEvent.new(:run_marker, %{phase: :finished, exit_code: exit_code})
    broadcast_stream_event(task_id, event, agent_line: false)
    # Durable store should hold the full transcript once the run ends.
    Svarm.RunLog.flush(task_id)
    broadcast({:run_finished, task_id, exit_code})
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(Svarm.PubSub, @topic, message)
  end

  # Callers (AgentRegistry.run_started_meta / runners) always use atom keys.
  defp run_started_label(meta) when is_map(meta) do
    display = meta[:display_name] || meta[:assignee] || "Agent"
    role = meta[:role]
    attempt = meta[:attempt] || "?"
    role_suffix = if role, do: " (#{role})", else: ""
    "#{display}#{role_suffix} started · attempt #{attempt}"
  end
end
