defmodule SvarmWeb.BoardLive do
  @moduledoc "Real-time board and agent run log (agent work · human judgment)."
  use SvarmWeb, :live_view

  alias Svarm.{
    AgentQuestion,
    Approval,
    Board,
    Budget,
    Events,
    RunSteer,
    StreamEvent,
    Usage
  }

  alias SvarmWeb.Plugs.ApprovalsAuth

  import SvarmWeb.BoardLive.{Chrome, Column, RunConsole}
  import SvarmWeb.BoardLive.Helpers, only: [column_label: 1]

  @max_log_lines 400
  # Coalesce session-cost SQL on high-frequency orchestrator_status ticks.
  @status_cost_interval_ms 2_000

  # Compile-time stream atoms only (no String.to_atom on external input).
  @column_streams %{
    "todo" => :col_todo,
    "pending_approval" => :col_pending_approval,
    "in_progress" => :col_in_progress,
    "review" => :col_review,
    "done" => :col_done,
    "failed" => :col_failed
  }

  @impl true
  def mount(_params, session, socket) do
    agents = Board.list_agents()
    # Stamp only — freshness re-checked on each high-trust event (TTL wall clock)
    board_auth_at = ApprovalsAuth.session_board_auth_at(session)
    column_ids = Board.column_ids()

    socket =
      socket
      |> assign(:column_ids, column_ids)
      |> assign(:column_counts, Map.new(column_ids, &{&1, 0}))
      |> assign(:tasks_by_id, %{})
      |> assign(:task_count, 0)
      |> assign(:orchestrator, %{})
      |> assign(:selected_task_id, nil)
      |> assign(:run_logs, %{})
      |> assign(:run_meta, %{})
      |> assign(:task_costs, %{})
      |> assign(:costs, %{})
      |> assign(:agents, agents)
      |> assign(:running_started, %{})
      |> assign(:now_mono, System.monotonic_time(:millisecond))
      |> assign(:workload, %{})
      |> assign(:console_focused?, false)
      |> assign(:dev_routes, Application.get_env(:svarm, :dev_routes, false))
      |> assign(:demo_routes, Svarm.Demo.routes_enabled?())
      |> assign(:board_auth_at, board_auth_at)
      |> assign(:last_status_cost_mono, 0)
      |> assign(:board_error, nil)
      |> reset_column_streams(column_ids)

    # Dead GET still loads cards below without subscribing. On the connected
    # remount, subscribe first so PubSub during load_board is not dropped.
    if connected?(socket) do
      Events.subscribe()
      Phoenix.PubSub.subscribe(Svarm.PubSub, "approvals")
    end

    socket = load_board(socket)

    {:ok,
     assign(
       socket,
       :checklist,
       Board.instance_status(
         agents: agents,
         task_count: socket.assigns.task_count,
         tracker_error: socket.assigns.board_error
       )
     )}
  end

  @impl true
  def handle_params(%{"task" => id} = params, _uri, socket)
      when is_binary(id) and id != "" do
    attach? = attach_param?(params)
    {:noreply, select_task(socket, id, patch: false, attach: attach?)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:selected_task_id, nil)
     |> assign(:console_focused?, false)
     |> assign(:run_logs, %{})}
  end

  @impl true
  def handle_event("select_task", %{"id" => id}, socket) do
    {:noreply, select_task(socket, id)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, clear_selection(socket)}
  end

  def handle_event("approve_task", %{"id" => id}, socket) do
    case authorize_board_mutation(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, unauthorized_mutation_flash("approve"))}

      :ok ->
        case Approval.approve(id) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Approved #{id}")
             |> load_board()
             |> then(fn s ->
               if s.assigns.selected_task_id == id, do: select_task(s, id), else: s
             end)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Approval.flash_error(reason))}
        end
    end
  end

  def handle_event("reject_task", %{"id" => id}, socket) do
    case authorize_board_mutation(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, unauthorized_mutation_flash("reject"))}

      :ok ->
        case Approval.reject(id) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Rejected #{id}")
             |> load_board()
             |> then(fn s ->
               if s.assigns.selected_task_id == id, do: select_task(s, id), else: s
             end)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Approval.flash_error(reason))}
        end
    end
  end

  def handle_event("approve_overage", %{"id" => id}, socket) do
    case authorize_board_mutation(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, unauthorized_mutation_flash("approve overage"))}

      :ok ->
        case Budget.approve_overage(id) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Approved overage for #{id}")
             |> load_board()
             |> then(fn s ->
               if s.assigns.selected_task_id == id, do: select_task(s, id), else: s
             end)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Budget.flash_error(reason))}
        end
    end
  end

  def handle_event("answer_agent_question", params, socket) do
    case authorize_board_mutation(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, unauthorized_mutation_flash("answer"))}

      :ok ->
        id = params["id"] || params["task_id"]

        case AgentQuestion.answer(id, answer_attrs_from_params(params)) do
          {:ok, :injected} ->
            {:noreply,
             socket
             |> put_flash(:info, "Answer sent")
             |> load_board()
             |> then(fn s ->
               if s.assigns.selected_task_id == id, do: select_task(s, id), else: s
             end)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, AgentQuestion.flash_error(reason))}
        end
    end
  end

  def handle_event("cancel_agent_question", %{"id" => id}, socket) do
    case authorize_board_mutation(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, unauthorized_mutation_flash("dismiss"))}

      :ok ->
        case AgentQuestion.cancel(id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Question dismissed — run continues")
             |> load_board()
             |> then(fn s ->
               if s.assigns.selected_task_id == id, do: select_task(s, id), else: s
             end)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, AgentQuestion.flash_error(reason))}
        end
    end
  end

  def handle_event("steer_run", params, socket) do
    case authorize_board_mutation(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, unauthorized_mutation_flash("steer"))}

      :ok ->
        id = params["id"] || params["task_id"]

        case RunSteer.inject(id, params["message"] || "") do
          {:ok, :injected} ->
            {:noreply, put_flash(socket, :info, "Steer sent")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, RunSteer.flash_error(reason))}
        end
    end
  end

  def handle_event("abort_run", %{"id" => id}, socket) do
    case authorize_board_mutation(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, unauthorized_mutation_flash("abort"))}

      :ok ->
        case Board.abort_run(id) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Aborted #{id} — ticket returned to Todo")
             |> load_board()
             |> then(fn s ->
               if s.assigns.selected_task_id == id, do: select_task(s, id), else: s
             end)}

          {:error, :not_running} ->
            {:noreply, put_flash(socket, :error, Board.abort_flash_error(:not_running))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, Board.abort_flash_error(reason))}
        end
    end
  end

  def handle_event("complete_review", %{"id" => id}, socket) do
    case authorize_board_mutation(socket) do
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, unauthorized_mutation_flash("mark done"))}

      :ok ->
        case Board.complete_review(id) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Marked #{id} done")
             |> load_board()
             |> then(fn s ->
               if s.assigns.selected_task_id == id, do: select_task(s, id), else: s
             end)}

          {:error, :not_in_review} ->
            {:noreply, put_flash(socket, :error, "Task is not awaiting review")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not mark done: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("board_keydown", %{"key" => key}, socket) do
    {:noreply, handle_board_key(socket, key)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_board(socket)}
  end

  def handle_event("board_tick", _params, socket) do
    now = System.monotonic_time(:millisecond)
    # Streams freeze card DOM; re-insert only running cards so elapsed chips tick.
    running_ids = Map.get(socket.assigns.orchestrator, :running_ids, [])

    socket =
      Enum.reduce(running_ids, assign(socket, :now_mono, now), fn id, s ->
        restream_task(s, id)
      end)

    {:noreply, socket}
  end

  defp authorize_board_mutation(socket) do
    # Re-check config + wall-clock TTL on every event (credentials / expiry may change after mount)
    if ApprovalsAuth.authorize_board_mutation?(socket.assigns.board_auth_at) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp unauthorized_mutation_flash(action) do
    if ApprovalsAuth.credentials_configured?() do
      "Authentication required to #{action}. Sign in via /approvals (same APPROVALS_* credentials), then return to the board. Proof expires after a period of inactivity (default 8h)."
    else
      "Board mutations require APPROVALS_USER and APPROVALS_PASSWORD outside local dev. Configure them, sign in via /approvals, then return to the board."
    end
  end

  @impl true
  def handle_info({:task_updated, task}, socket) do
    task = card_task(task)

    socket =
      socket
      |> update_task_in_streams(task)
      |> maybe_append_status_marker(task)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:tasks_snapshot, tasks}, socket) do
    {:noreply, put_columns(socket, Enum.map(tasks, &card_task/1))}
  end

  @impl true
  def handle_info({:orchestrator_status, status}, socket) do
    now = System.monotonic_time(:millisecond)
    last = socket.assigns.last_status_cost_mono || 0

    {session_cost, last} =
      if now - last >= @status_cost_interval_ms do
        {Usage.session_cost_summary(), now}
      else
        {Map.get(socket.assigns.orchestrator, :session_cost), last}
      end

    status =
      if session_cost do
        Map.put(status, :session_cost, session_cost)
      else
        status
      end

    old_running = MapSet.new(Map.get(socket.assigns.orchestrator, :running_ids, []))
    new_running = MapSet.new(Map.get(status, :running_ids, []))
    old_retry = MapSet.new(Map.get(socket.assigns.orchestrator, :retry_ids, []))
    new_retry = MapSet.new(Map.get(status, :retry_ids, []))

    # Re-stream only cards whose running/retry chrome changed.
    refresh_ids =
      MapSet.union(
        MapSet.symmetric_difference(old_running, new_running),
        MapSet.symmetric_difference(old_retry, new_retry)
      )

    socket =
      socket
      |> assign(:orchestrator, status)
      |> assign(:running_started, Map.get(status, :running_started, %{}))
      |> assign(:last_status_cost_mono, last)

    socket = Enum.reduce(refresh_ids, socket, fn id, s -> restream_task(s, id) end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_started, task_id, meta}, socket) do
    started_mono = meta[:started_mono_ms] || System.monotonic_time(:millisecond)

    socket =
      socket
      |> assign(:run_meta, Map.put(socket.assigns.run_meta, task_id, meta))
      |> assign(:running_started, Map.put(socket.assigns.running_started, task_id, started_mono))
      # Stream cards freeze DOM; restream so review glance can read PR from run_meta.
      |> restream_task(task_id)

    # The preceding :run_marker stream event owns display. Auto-select hydrates
    # that persisted marker from RunLog.
    socket =
      cond do
        is_nil(socket.assigns.selected_task_id) ->
          select_task(socket, task_id, patch: false, attach: true)

        socket.assigns.selected_task_id == task_id ->
          maybe_focus_running(socket, task_id)

        true ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:stream_event, task_id, event}, socket) do
    {:noreply, append_stream_event(socket, task_id, event)}
  end

  # Events still emits this compatibility tuple after :stream_event. Typed
  # display owns the append so each chunk appears once.
  @impl true
  def handle_info({:agent_line, _task_id, _line}, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:run_finished, task_id, _exit_code}, socket) do
    # Fetch detailed cost + update card summary + session total
    costs = fetch_task_cost(task_id, socket.assigns.task_costs)

    session_cost = Usage.session_cost_summary()
    orchestrator = Map.put(socket.assigns.orchestrator, :session_cost, session_cost)

    running_started = Map.delete(socket.assigns.running_started, task_id)

    socket =
      socket
      |> assign(:task_costs, costs)
      |> assign(:orchestrator, orchestrator)
      |> assign(:running_started, running_started)
      |> update_costs_for_task(task_id)
      # Stream items freeze card DOM; re-insert so cost badges pick up new @costs.
      |> restream_task(task_id)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:approved, _task_id}, socket), do: {:noreply, load_board(socket)}

  @impl true
  def handle_info({:rejected, _task_id}, socket), do: {:noreply, load_board(socket)}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div
        id="board-root"
        phx-hook="BoardTick"
        phx-window-keydown="board_keydown"
        class="max-w-[1600px] mx-auto space-y-6"
      >
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Board</h1>
            <p class="text-sm opacity-70">
              Agent work · human judgment · review Evidence is informational (merge on GitHub)
            </p>
          </div>
          <div class="flex gap-2 items-center text-sm">
            <button type="button" phx-click="refresh" class="btn btn-sm btn-ghost">
              Refresh
            </button>
            <a href={~p"/approvals"} class="btn btn-sm btn-outline">Approvals</a>
            <%= if @demo_routes do %>
              <.link
                href={~p"/dev/demo/seed?goal=create+a+cool+app"}
                method="post"
                class="btn btn-sm btn-primary"
              >
                Seed demo
              </.link>
            <% end %>
          </div>
        </div>

        <%= cond do %>
          <% @board_error -> %>
            <.board_load_error message={@board_error} />
          <% @task_count == 0 -> %>
            <.board_empty demo_routes={@demo_routes} checklist={@checklist} />
          <% true -> %>
            <.demo_bridge_banner tasks_by_id={@tasks_by_id} checklist={@checklist} />
            <.orchestrator_bar
              orchestrator={@orchestrator}
              agents={@agents}
              now_mono={@now_mono}
            />

            <details class="text-xs opacity-60 group">
              <summary class="cursor-pointer select-none list-none opacity-50 hover:opacity-80">
                Keyboard
              </summary>
              <p class="mt-1 opacity-70">
                <kbd class="font-mono rounded bg-base-200 px-1">j</kbd>/<kbd class="font-mono rounded bg-base-200 px-1">k</kbd>
                select · <kbd class="font-mono rounded bg-base-200 px-1">Esc</kbd>
                clear
              </p>
            </details>

            <div class="flex gap-4 overflow-x-auto pb-4 min-h-[280px]">
              <%= for col <- @column_ids do %>
                <.column
                  id={col}
                  title={column_label(col)}
                  status_id={col}
                  tasks_stream={column_stream(assigns, col)}
                  count={Map.get(@column_counts, col, 0)}
                  selected_task_id={@selected_task_id}
                  running_ids={Map.get(@orchestrator, :running_ids, [])}
                  retry_ids={Map.get(@orchestrator, :retry_ids, [])}
                  running_started={@running_started}
                  now_mono={@now_mono}
                  workload={@workload}
                  agents={@agents}
                  costs={@costs}
                  run_meta={@run_meta}
                />
              <% end %>
            </div>

            <.run_console
              task_id={@selected_task_id}
              task={selected_task(@tasks_by_id, @selected_task_id)}
              log={Map.get(@run_logs, @selected_task_id, "")}
              meta={Map.get(@run_meta, @selected_task_id, %{})}
              agents={@agents}
              cost={Map.get(@task_costs, @selected_task_id)}
              running_started={@running_started}
              now_mono={@now_mono}
              focused={@console_focused?}
              running?={@selected_task_id in Map.get(@orchestrator, :running_ids, [])}
            />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp load_board(socket) do
    case Board.fetch_tasks() do
      {:ok, tasks} ->
        costs = compute_costs(tasks)
        orchestrator = Board.orchestrator_status()

        # Attach session cost for the bar
        session_cost = Usage.session_cost_summary()
        orchestrator = Map.put(orchestrator, :session_cost, session_cost)
        now = System.monotonic_time(:millisecond)

        socket
        |> put_columns(tasks, costs)
        |> assign(:orchestrator, orchestrator)
        |> assign(:running_started, Map.get(orchestrator, :running_started, %{}))
        |> assign(:last_status_cost_mono, now)
        |> assign(:board_error, nil)

      {:error, reason} ->
        message = Board.tracker_error_message(reason)
        orchestrator = Board.orchestrator_status()
        now = System.monotonic_time(:millisecond)

        socket
        |> put_flash(:error, message)
        |> assign(:board_error, message)
        |> assign(:task_count, 0)
        |> assign(:tasks_by_id, %{})
        |> assign(:orchestrator, orchestrator)
        |> assign(:running_started, Map.get(orchestrator, :running_started, %{}))
        |> assign(:last_status_cost_mono, now)
    end
  end

  # One batched usage query for all visible tasks (no per-task N+1).
  defp compute_costs(tasks) do
    tasks
    |> Enum.map(& &1.id)
    |> Usage.task_cost_summaries()
  end

  defp put_columns(socket, tasks, costs \\ nil) do
    costs = costs || compute_costs(tasks)
    column_ids = Board.column_ids()
    grouped = Board.group_by_status(tasks)
    counts = Map.new(column_ids, fn col -> {col, length(Map.get(grouped, col, []))} end)
    tasks_by_id = Map.new(tasks, fn t -> {t.id, card_task(t)} end)

    socket =
      Enum.reduce(column_ids, socket, fn col, s ->
        items = Map.get(grouped, col, []) |> Enum.map(&card_task/1)

        case stream_name(col) do
          nil -> s
          name -> stream(s, name, items, reset: true)
        end
      end)

    socket
    |> assign(:column_ids, column_ids)
    |> assign(:column_counts, counts)
    |> assign(:tasks_by_id, tasks_by_id)
    |> assign(:task_count, length(tasks))
    |> assign(:costs, costs)
    |> assign(:workload, Board.counts_by_assignee(tasks))
  end

  defp update_task_in_streams(socket, task) do
    incoming = card_task(task)
    old = Map.get(socket.assigns.tasks_by_id, incoming.id)
    # Partial PubSub payloads (e.g. status-only) merge onto the known card.
    task = if old, do: Map.merge(old, incoming), else: incoming
    old_status = old && old.status
    new_status = task.status

    socket =
      cond do
        is_nil(old_status) ->
          insert_into_column(socket, new_status, task)

        old_status == new_status ->
          insert_into_column(socket, new_status, task)

        true ->
          socket
          |> delete_from_column(old_status, old || task)
          |> insert_into_column(new_status, task)
      end

    tasks_by_id = Map.put(socket.assigns.tasks_by_id, task.id, task)
    counts = recompute_column_counts(tasks_by_id, socket.assigns.column_ids)
    workload = Board.counts_by_assignee(Map.values(tasks_by_id))

    socket
    |> assign(:tasks_by_id, tasks_by_id)
    |> assign(:column_counts, counts)
    |> assign(:task_count, map_size(tasks_by_id))
    |> assign(:workload, workload)
  end

  defp insert_into_column(socket, status, task) do
    case stream_name(status) do
      nil -> socket
      name -> stream_insert(socket, name, task)
    end
  end

  defp delete_from_column(socket, status, task) do
    case stream_name(status) do
      nil -> socket
      name -> stream_delete(socket, name, task)
    end
  end

  defp restream_task(socket, id) when is_binary(id) do
    case Map.get(socket.assigns.tasks_by_id, id) do
      nil -> socket
      task -> insert_into_column(socket, task.status, task)
    end
  end

  defp restream_task(socket, _), do: socket

  defp reset_column_streams(socket, column_ids) do
    Enum.reduce(column_ids, socket, fn col, s ->
      case stream_name(col) do
        nil -> s
        name -> stream(s, name, [])
      end
    end)
  end

  defp stream_name(status) when is_binary(status), do: Map.get(@column_streams, status)
  defp stream_name(_), do: nil

  defp column_stream(assigns, col) do
    case stream_name(col) do
      nil -> []
      name -> Map.get(assigns.streams, name, [])
    end
  end

  defp recompute_column_counts(tasks_by_id, column_ids) do
    grouped = Enum.group_by(Map.values(tasks_by_id), & &1.status)
    Map.new(column_ids, fn col -> {col, length(Map.get(grouped, col, []))} end)
  end

  # Drop body / raw so streams never retain large TEXT payloads.
  defp card_task(task) when is_map(task) do
    Map.drop(task, [:body, "body", :raw, "raw"])
  end

  # Marker already persisted once in Events.broadcast_task_updated/1.
  # Status-less payloads (wait-field clears) must not crash or log a line.
  defp maybe_append_status_marker(socket, %{id: id, status: status})
       when is_binary(id) and is_binary(status) do
    append_display_log(socket, id, "[board] status → #{status}\n")
  end

  defp maybe_append_status_marker(socket, _), do: socket

  defp append_stream_event(socket, task_id, %{kind: :tool_end, payload: payload} = event) do
    case StreamEvent.to_text(event) do
      "" ->
        # ponytail: successful tool ends are live-only while RunLog stays text-only.
        name =
          case payload[:name] do
            name when is_binary(name) and name != "" -> String.replace(name, "\n", " ")
            _ -> "tool"
          end

        append_display_log(socket, task_id, "\n[tool #{name} complete]\n")

      text ->
        append_display_log(socket, task_id, text)
    end
  end

  defp append_stream_event(socket, task_id, event) do
    case StreamEvent.to_text(event) do
      "" -> socket
      text -> append_display_log(socket, task_id, text)
    end
  end

  defp append_display_log(socket, task_id, chunk) when is_binary(task_id) do
    if socket.assigns.selected_task_id == task_id do
      logs = socket.assigns.run_logs
      prev = Map.get(logs, task_id, "")
      assign(socket, :run_logs, Map.put(logs, task_id, trim_log(prev <> chunk)))
    else
      socket
    end
  end

  defp trim_log(text) do
    lines = String.split(text, "\n", trim: false)

    if length(lines) > @max_log_lines do
      lines |> Enum.take(-@max_log_lines) |> Enum.join("\n")
    else
      text
    end
  end

  defp fetch_task_cost(task_id, existing_costs) do
    if Map.has_key?(existing_costs, task_id) do
      existing_costs
    else
      report = Usage.task_cost(task_id)

      if report.record_count > 0 do
        Map.put(existing_costs, task_id, report)
      else
        existing_costs
      end
    end
  end

  defp update_costs_for_task(socket, task_id) do
    case Usage.task_cost_summary(task_id) do
      nil ->
        socket

      summary ->
        assign(socket, :costs, Map.put(socket.assigns.costs, task_id, summary))
    end
  end

  defp selected_task(_tasks_by_id, nil), do: nil
  defp selected_task(tasks_by_id, id), do: Map.get(tasks_by_id, id)

  defp answer_attrs_from_params(params) when is_map(params) do
    %{
      confirmed: params["confirmed"],
      value: params["value"],
      request_id: params["request_id"]
    }
  end

  defp select_task(socket, id, opts \\ []) do
    patch? = Keyword.get(opts, :patch, true)
    attach? = Keyword.get(opts, :attach, false)
    prev_id = socket.assigns.selected_task_id
    costs = fetch_task_cost(id, socket.assigns.task_costs)
    log = Svarm.RunLog.get(id) |> trim_log()
    focused? = attach? or task_running?(socket, id)

    socket =
      socket
      |> assign(:selected_task_id, id)
      |> assign(:task_costs, costs)
      |> assign(:run_logs, %{id => log})
      |> assign(:console_focused?, focused?)
      # Stream items do not re-render on assign changes — refresh selection chrome.
      |> restream_task(prev_id)
      |> restream_task(id)

    if patch? do
      query = if attach?, do: [task: id, attach: 1], else: [task: id]
      push_patch(socket, to: ~p"/board?#{query}", replace: true)
    else
      socket
    end
  end

  defp clear_selection(socket) do
    prev_id = socket.assigns.selected_task_id

    socket
    |> assign(:selected_task_id, nil)
    |> assign(:console_focused?, false)
    |> assign(:run_logs, %{})
    |> restream_task(prev_id)
    |> push_patch(to: ~p"/board", replace: true)
  end

  defp attach_param?(%{"attach" => v}) when v in ["1", "true"], do: true
  defp attach_param?(_), do: false

  defp task_running?(socket, id) do
    running = Map.get(socket.assigns.orchestrator, :running_ids, [])
    id in running or Map.has_key?(socket.assigns.running_started, id)
  end

  defp maybe_focus_running(socket, task_id) do
    if socket.assigns.selected_task_id == task_id and task_running?(socket, task_id) do
      assign(socket, :console_focused?, true)
    else
      socket
    end
  end

  defp handle_board_key(socket, "Escape"), do: clear_selection(socket)

  defp handle_board_key(socket, key) when key in ["j", "J", "ArrowDown"] do
    select_relative(socket, 1)
  end

  defp handle_board_key(socket, key) when key in ["k", "K", "ArrowUp"] do
    select_relative(socket, -1)
  end

  defp handle_board_key(socket, _), do: socket

  defp select_relative(socket, delta) do
    ids = task_ids_in_order(socket.assigns.tasks_by_id, socket.assigns.column_ids)

    case ids do
      [] ->
        socket

      list ->
        cur = socket.assigns.selected_task_id
        idx = list |> Enum.find_index(&(&1 == cur)) |> wrap_index(delta)
        next = Enum.at(list, Integer.mod(idx + delta, length(list)))
        select_task(socket, next)
    end
  end

  defp task_ids_in_order(tasks_by_id, column_ids) do
    by_status = Enum.group_by(Map.values(tasks_by_id), & &1.status)

    Enum.flat_map(column_ids, fn col ->
      by_status
      |> Map.get(col, [])
      |> Enum.sort_by(&{&1.priority || 0, &1.created_at || 0, &1.id})
      |> Enum.map(& &1.id)
    end)
  end

  defp wrap_index(nil, delta) when delta > 0, do: -1
  defp wrap_index(nil, _delta), do: 0
  defp wrap_index(i, _delta), do: i
end
