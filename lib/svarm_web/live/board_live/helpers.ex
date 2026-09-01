defmodule SvarmWeb.BoardLive.Helpers do
  @moduledoc """
  Pure labels, formatters, and run-log classification for the team board.

  Presentational LiveView modules call these helpers; the BoardLive process
  keeps mount, events, streams, and Approval mutations.
  """

  alias Svarm.{AgentRegistry, Board}

  def panel_identity(%{meta: meta, task: task, agents: agents}) when is_map(task) do
    if map_size(meta) > 0 do
      identity_from_meta(meta)
    else
      AgentRegistry.identity(task.assignee, agents)
    end
  end

  def panel_identity(%{task: nil, agents: _}),
    do: %{display_name: "Agent", avatar: "🤖", role: nil}

  defp identity_from_meta(meta) when is_map(meta) do
    %{
      assignee: meta[:assignee] || "default",
      display_name: meta[:display_name] || meta[:assignee] || "Agent",
      role: meta[:role],
      avatar: meta[:avatar] || "🤖",
      adapter: meta[:adapter],
      model: meta[:model]
    }
  end

  def column_empty_hint("todo"), do: "Task queue: dispatch or seed"
  def column_empty_hint("pending_approval"), do: "No gates pending"
  def column_empty_hint("in_progress"), do: "Nothing running"
  def column_empty_hint("review"), do: "No work waiting for human review"
  def column_empty_hint("done"), do: "No completed tasks"
  def column_empty_hint("failed"), do: "No failures"
  def column_empty_hint(_), do: "-"

  def agent_count_label(0), do: "0 agents"
  def agent_count_label(1), do: "1 agent"
  def agent_count_label(n), do: "#{n} agents"

  def busy_line(orchestrator, agents) do
    n = Map.get(orchestrator, :running, 0)

    names =
      orchestrator
      |> Map.get(:active_assignees, [])
      |> Enum.map(fn key ->
        AgentRegistry.identity(key, agents).display_name
      end)
      |> Enum.uniq()

    case names do
      [] ->
        "#{n} task#{if n == 1, do: "", else: "s"} running"

      list ->
        joined = Enum.join(list, ", ")
        "#{n} running · #{joined}"
    end
  end

  def card_activity(task, running_ids, retry_ids) do
    id = task.id
    wait = Board.wait_reason(task)

    %{
      running: id in running_ids,
      retrying: id in retry_ids,
      wait_reason: wait,
      pending_approval: wait == :approval
    }
  end

  def wait_chip_class(:ci_circuit), do: "badge-outline badge-error"
  def wait_chip_class(:changes_requested), do: "badge-warning"
  def wait_chip_class(:agent_question), do: "badge-outline badge-warning"
  def wait_chip_class(_), do: "badge-outline badge-warning"

  def question_options(%{"options" => list}) when is_list(list),
    do: Enum.map(list, &option_pair/1)

  def question_options(_), do: []

  def string_key_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp option_pair(%{"label" => label, "value" => value}),
    do: {to_string(label), to_string(value)}

  defp option_pair(%{label: label, value: value}), do: {to_string(label), to_string(value)}
  defp option_pair(value) when is_binary(value), do: {value, value}
  defp option_pair(value), do: {to_string(value), to_string(value)}

  def review_badge(task) do
    case Board.wait_reason(task) do
      :changes_requested -> {"Changes requested", "badge-warning"}
      :ci_circuit -> {"CI retries exhausted", "badge-error"}
      _ -> {"Needs review", "badge-warning"}
    end
  end

  def human_column?(status) when status in ["pending_approval", "review"], do: true
  def human_column?(_), do: false

  def format_elapsed(nil, _now), do: "…"

  def format_elapsed(started_mono, now) when is_integer(started_mono) and is_integer(now) do
    sec = max(div(now - started_mono, 1000), 0)
    format_duration(sec)
  end

  def format_elapsed(_, _), do: "…"

  defp format_duration(sec) when sec < 60, do: "#{sec}s"

  defp format_duration(sec) when sec < 3600 do
    m = div(sec, 60)
    s = rem(sec, 60)
    "#{m}m #{s}s"
  end

  defp format_duration(sec) do
    h = div(sec, 3600)
    m = rem(div(sec, 60), 60)
    "#{h}h #{m}m"
  end

  def column_label("todo"), do: "Todo"
  def column_label("pending_approval"), do: "Needs approval"
  def column_label("in_progress"), do: "In progress"
  def column_label("review"), do: "Review"
  def column_label("done"), do: "Done"
  def column_label("failed"), do: "Failed"

  def column_label(other) when is_binary(other) do
    other
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def column_label(_), do: "Column"

  def type_label("code"), do: "Code"
  def type_label("research"), do: "Research"
  def type_label("docs"), do: "Docs"
  def type_label("documentation"), do: "Docs"
  def type_label("test"), do: "Test"
  def type_label("review"), do: "Review"
  def type_label(nil), do: "Task"
  def type_label(""), do: "Task"

  def type_label(other) when is_binary(other) do
    other
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def type_label(_), do: "Task"

  def approval_mode_label(o) when is_map(o) do
    o |> get_approval_mode() |> approval_mode_to_label()
  end

  defp get_approval_mode(%{approval: %{mode: m}}), do: m
  defp get_approval_mode(%{approval: %{"mode" => m}}), do: m
  defp get_approval_mode(_), do: nil

  defp approval_mode_to_label(:off), do: "Approval off"
  defp approval_mode_to_label("off"), do: "Approval off"
  defp approval_mode_to_label(:all), do: "Approve all"
  defp approval_mode_to_label("all"), do: "Approve all"
  defp approval_mode_to_label(:untrusted), do: "Approve untrusted"
  defp approval_mode_to_label("untrusted"), do: "Approve untrusted"
  defp approval_mode_to_label(_), do: nil

  def orchestrator_idle?(o) when is_map(o) do
    Map.get(o, :running, 0) == 0 and
      Map.get(o, :claimed, 0) == 0 and
      Map.get(o, :retrying, 0) == 0
  end

  def orchestrator_idle?(_), do: true

  def session_cost_line(o) when is_map(o) do
    case Map.get(o, :session_cost) do
      %{record_count: n, total_cost_usd: usd, estimated: true} when is_integer(n) and n > 0 ->
        "$#{usd} est."

      %{record_count: n, total_cost_usd: usd} when is_integer(n) and n > 0 ->
        "$#{usd}"

      _ ->
        nil
    end
  end

  def session_cost_line(_), do: nil

  def last_poll_label(o, now_mono) when is_map(o) and is_integer(now_mono) do
    case Map.get(o, :last_tick_mono_ms) do
      t when is_integer(t) ->
        sec = max(div(now_mono - t, 1000), 0)
        format_elapsed_ago(sec)

      _ ->
        nil
    end
  end

  def last_poll_label(_, _), do: nil

  defp format_elapsed_ago(sec) when sec < 5, do: "just now"
  defp format_elapsed_ago(sec) when sec < 60, do: "#{sec}s ago"
  defp format_elapsed_ago(sec) when sec < 3600, do: "#{div(sec, 60)}m ago"
  defp format_elapsed_ago(sec), do: "#{div(sec, 3600)}h ago"

  def duration_label(running_started, task_id, now_mono)
      when is_map_key(running_started, task_id) and is_integer(now_mono) do
    started = Map.get(running_started, task_id)
    sec = max(div(now_mono - started, 1000), 0)
    format_duration(sec)
  end

  def duration_label(_, _, _), do: nil

  def format_evidence_age(sec) when is_integer(sec) and sec >= 0 do
    format_duration(sec)
  end

  def format_evidence_age(_), do: "—"

  def classify_log(log) when is_binary(log) do
    # ponytail: stable projection prefixes are the restore boundary while RunLog is text-only.
    log
    |> String.split("\n")
    |> compact_log_spacing()
    |> Enum.map(&classify_log_line/1)
  end

  def classify_log(_), do: []

  defp compact_log_spacing(lines) do
    lines
    |> collapse_blank_lines()
    |> trim_blank_lines()
    |> drop_projection_spacers()
  end

  defp drop_projection_spacers([]), do: []

  defp drop_projection_spacers(lines) do
    [nil | lines]
    |> Enum.chunk_every(3, 1, [nil])
    |> Enum.flat_map(&keep_log_line/1)
  end

  defp collapse_blank_lines(lines) do
    lines
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.flat_map(fn
      ["" | _] -> [""]
      run -> run
    end)
  end

  defp trim_blank_lines(lines) do
    lines
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp keep_log_line([previous, "", next]) do
    if typed_projection_line?(previous) or typed_projection_line?(next), do: [], else: [""]
  end

  defp keep_log_line([_previous, line, _next]), do: [line]

  defp typed_projection_line?("--- " <> _), do: true
  defp typed_projection_line?("$ " <> _), do: true
  defp typed_projection_line?("[tool " <> _), do: true
  defp typed_projection_line?(_), do: false

  defp classify_log_line(""), do: {"", nil, nil, "h-1 overflow-hidden"}

  defp classify_log_line("--- " <> _ = line) do
    {line, "run_marker", nil, "text-neutral-content/50"}
  end

  defp classify_log_line("$ " <> _ = line) do
    {line, "tool_start", nil, "text-cyan-300"}
  end

  defp classify_log_line("[tool " <> _ = line), do: classify_tool_line(line)

  defp classify_log_line("[board]" <> _ = line) do
    {line, "text", "board", "text-[10px] text-neutral-content/35"}
  end

  defp classify_log_line(line) do
    cond do
      String.contains?(line, ["error", "Error"]) ->
        {line, "text", "error", "text-red-300"}

      String.contains?(line, ["warning", "Warning"]) ->
        {line, "text", "warning", "text-amber-300"}

      true ->
        {line, "text", nil, "text-neutral-content/85"}
    end
  end

  defp classify_tool_line(line) do
    cond do
      String.ends_with?(line, " failed]") ->
        {line, "tool_end", "error", "text-red-300"}

      String.ends_with?(line, " complete]") ->
        {line, "tool_end", "ok", "text-emerald-300"}

      true ->
        {line, "text", nil, "text-neutral-content/85"}
    end
  end

  def stream_entry_label("tool_start", _), do: "tool"
  def stream_entry_label("tool_end", "error"), do: "fail"
  def stream_entry_label("tool_end", _), do: "done"
  def stream_entry_label("run_marker", _), do: "run"
  def stream_entry_label(_, _), do: ""

  def monogram(%{display_name: name}) when is_binary(name) and name != "" do
    name
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "?"
      c -> String.upcase(c)
    end
  end

  def monogram(_), do: "?"
end
