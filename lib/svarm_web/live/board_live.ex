defmodule SvarmWeb.BoardLive do
  @moduledoc "Real-time board and agent run log (agent work · human judgment)."
  use SvarmWeb, :live_view

  alias Svarm.{
    AgentQuestion,
    AgentRegistry,
    Approval,
    Board,
    Budget,
    Events,
    RunSteer,
    StreamEvent,
    Usage
  }

  alias SvarmWeb.Plugs.ApprovalsAuth

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
      |> reset_column_streams(column_ids)
      |> load_board()

    # Dead GET must already include cards. Subscribe only after the socket is up.
    if connected?(socket) do
      Events.subscribe()
      Phoenix.PubSub.subscribe(Svarm.PubSub, "approvals")
    end

    {:ok,
     assign(
       socket,
       :checklist,
       Board.instance_status(agents: agents, task_count: socket.assigns.task_count)
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
            />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp load_board(socket) do
    tasks = Board.list_tasks()
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

  attr :tasks_by_id, :map, required: true
  attr :checklist, :map, default: %{}

  defp demo_bridge_banner(assigns) do
    has_demo_tasks =
      Enum.any?(assigns.tasks_by_id, fn {_id, t} ->
        assignee = t.assignee || ""
        String.starts_with?(assignee, "demo_")
      end)

    tracker_kind = get_in(assigns.checklist, [:tracker_kind]) || :local

    assigns =
      assign(assigns,
        show?: has_demo_tasks and tracker_kind == :local,
        has_demo_tasks: has_demo_tasks
      )

    ~H"""
    <%= if @show? do %>
      <div class="rounded-lg border border-primary/20 bg-primary/5 px-4 py-2.5 text-sm flex items-center gap-3">
        <span class="text-primary font-medium">Demo mode</span>
        <span class="opacity-70">Running mock agents. Connect GitHub for real agent work.</span>
        <a
          href="https://github.com/svarm-dev/svarm/blob/main/GETTING-STARTED.md"
          class="btn btn-xs btn-outline ml-auto shrink-0"
          target="_blank"
        >
          Get started
        </a>
      </div>
    <% end %>
    """
  end

  defp board_empty(assigns) do
    c = assigns.checklist || %{}

    assigns =
      assign(assigns,
        workflow_ok?: Map.get(c, :workflow_loaded?, false),
        workflow_path: Map.get(c, :workflow_path) || "-",
        tracker_label: Map.get(c, :tracker_label) || "local",
        agent_count: Map.get(c, :agent_count) || 0,
        approval_mode: Map.get(c, :approval_mode) || "untrusted",
        approvals_auth?: Map.get(c, :approvals_auth?, false),
        setup_complete?: Map.get(c, :setup_complete?, false),
        provider_configured?: Map.get(c, :provider_configured?, false)
      )

    ~H"""
    <section
      class="rounded-lg border border-base-300 bg-base-200/70 px-6 py-8 sm:px-8"
      aria-labelledby="board-empty-title"
    >
      <h2 id="board-empty-title" class="text-lg font-semibold tracking-tight">
        All quiet. No tickets yet.
      </h2>
      <p class="mt-2 max-w-2xl text-sm opacity-80">
        Live view of agent work and human wait states. Cards move as agents claim work;
        open a card for streamed output and per-ticket cost. Approvals and review are the human steps.
        On <span class="font-medium">review</span>
        cards, Evidence (PR, attempts, cost, age) is informational —
        humans still merge on GitHub.
      </p>

      <ul class="mt-5 max-w-2xl space-y-2 text-sm" aria-label="First-run checklist">
        <li class="flex gap-2">
          <span class="font-mono text-xs opacity-60 w-5 shrink-0">{if @workflow_ok?,
            do: "✓",
            else: "○"}</span>
          <span>
            Workflow loaded <span class="font-mono text-xs opacity-60">({@workflow_path})</span>
          </span>
        </li>
        <li class="flex gap-2">
          <span class="font-mono text-xs opacity-60 w-5 shrink-0">{if @provider_configured?,
            do: "✓",
            else: "○"}</span>
          <span>
            Provider key
            <%= if not @setup_complete? do %>
              ·
              <a href={~p"/setup"} class="underline underline-offset-2 hover:opacity-100">
                Configure in /setup
              </a>
            <% end %>
          </span>
        </li>
        <li class="flex gap-2">
          <span class="font-mono text-xs opacity-60 w-5 shrink-0">✓</span>
          <span>
            Tracker: <span class="font-mono text-xs">{@tracker_label}</span>
          </span>
        </li>
        <li class="flex gap-2">
          <span class="font-mono text-xs opacity-60 w-5 shrink-0">{if @agent_count > 0,
            do: "✓",
            else: "○"}</span>
          <span>Agents registered ({@agent_count})</span>
        </li>
        <li class="flex gap-2">
          <span class="font-mono text-xs opacity-60 w-5 shrink-0">{if @approvals_auth? or
                                                                        @approval_mode == "off",
                                                                      do: "✓",
                                                                      else: "○"}</span>
          <span>
            Approvals: <span class="font-mono text-xs">mode: {@approval_mode}</span>
            <%= if @approvals_auth? do %>
              · auth OK
            <% else %>
              · set <code class="rounded bg-base-300 px-1 font-mono text-xs">APPROVALS_USER</code>
              / <code class="rounded bg-base-300 px-1 font-mono text-xs">APPROVALS_PASSWORD</code>
              for /approvals
            <% end %>
          </span>
        </li>
        <li class="flex gap-2">
          <span class="font-mono text-xs opacity-60 w-5 shrink-0">○</span>
          <span>
            <%= if @demo_routes do %>
              Seed demo (below) or create a labeled issue on your tracker
            <% else %>
              Seed via Docker
              <code class="rounded bg-base-300 px-1 font-mono text-xs">--profile demo</code>
              or create a labeled issue
            <% end %>
          </span>
        </li>
      </ul>

      <div class="mt-6 flex flex-wrap items-center gap-3">
        <%= if not @setup_complete? do %>
          <a href={~p"/setup"} class="btn btn-outline btn-sm">Open setup</a>
        <% end %>
        <%= if @demo_routes do %>
          <.link
            href={~p"/dev/demo/seed?goal=create+a+cool+app"}
            method="post"
            class="btn btn-primary btn-sm"
          >
            Seed demo
          </.link>
          <span class="text-xs opacity-60">No API keys · mock agents · ~1 minute to aha</span>
        <% else %>
          <p class="text-sm opacity-70">
            Point WORKFLOW.md at your tracker and open eligible issues, or run
            Docker with <code class="rounded bg-base-300 px-1 font-mono text-xs">--profile demo</code>
            for a zero-key board.
          </p>
        <% end %>
      </div>
    </section>
    """
  end

  attr :orchestrator, :map, required: true
  attr :agents, :map, default: %{}
  attr :now_mono, :integer, default: 0

  defp orchestrator_bar(assigns) do
    o = assigns.orchestrator
    idle? = orchestrator_idle?(o)
    assigns = assign(assigns, :idle?, idle?)

    ~H"""
    <div class="flex flex-col gap-2 w-full max-w-5xl">
      <%= if budget_block = Map.get(@orchestrator, :last_budget_block) do %>
        <p
          class="text-sm rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-warning-content"
          role="status"
        >
          Budget cap blocked new spawn for
          <span class="font-mono">{budget_block[:task_id] || budget_block["task_id"]}</span>
          ({budget_block[:scope] || budget_block["scope"]}: spent ${budget_block[:spent] ||
            budget_block["spent"]} / cap ${budget_block[:cap] || budget_block["cap"]}).
          <%= if (budget_block[:mode] || budget_block["mode"]) == :hold or
                   (budget_block[:mode] || budget_block["mode"]) == "hold" do %>
            Ticket held for overage approval; in-flight runs continue.
          <% else %>
            In-flight runs continue; raise or clear caps to dispatch more.
          <% end %>
        </p>
      <% end %>

      <%= if Map.get(@orchestrator, :running, 0) > 0 do %>
        <p class="text-sm font-medium flex items-center gap-2">
          <span class="inline-block w-2 h-2 rounded-full bg-primary motion-safe:animate-pulse" />
          {busy_line(@orchestrator, @agents)}
        </p>
      <% end %>

      <%= if @idle? do %>
        <p class="text-sm opacity-60 rounded-lg border border-base-300 bg-base-200/60 px-3 py-2">
          Orchestrator idle. Nothing running.
          <%= if last_poll_label(@orchestrator, @now_mono) do %>
            · last poll {last_poll_label(@orchestrator, @now_mono)}
          <% end %>
          <%= if approval_mode_label(@orchestrator) do %>
            · {approval_mode_label(@orchestrator)}
          <% end %>
          <%= if session_cost_line(@orchestrator) do %>
            · session <span class="font-mono">{session_cost_line(@orchestrator)}</span>
          <% end %>
        </p>
      <% else %>
        <div class="flex flex-wrap gap-3 rounded-lg border border-base-300 bg-base-200 px-3 py-2 text-sm">
          <div>
            <span class="text-xs opacity-60 block">Running</span>
            <span class="font-semibold text-primary">{Map.get(@orchestrator, :running, 0)}</span>
            <span class="text-xs opacity-50 ml-1">
              {agent_count_label(Map.get(@orchestrator, :active_agent_count, 0))}
            </span>
          </div>
          <div>
            <span class="text-xs opacity-60 block">Claimed</span>
            <span class="font-semibold">{Map.get(@orchestrator, :claimed, 0)}</span>
          </div>
          <%= if Map.get(@orchestrator, :retrying, 0) > 0 do %>
            <div>
              <span class="text-xs opacity-60 block">Retrying</span>
              <span class="font-semibold text-warning">{Map.get(@orchestrator, :retrying, 0)}</span>
            </div>
          <% end %>
          <div>
            <span class="text-xs opacity-60 block">Done (session)</span>
            <span class="font-semibold">{Map.get(@orchestrator, :completed, 0)}</span>
          </div>
          <%= if approval_mode_label(@orchestrator) do %>
            <div>
              <span class="text-xs opacity-60 block">Gates</span>
              <span class="font-semibold">{approval_mode_label(@orchestrator)}</span>
            </div>
          <% end %>
          <%= if session_cost_line(@orchestrator) do %>
            <div>
              <span class="text-xs opacity-60 block">Session cost</span>
              <span class="font-semibold font-mono">{session_cost_line(@orchestrator)}</span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :status_id, :string, required: true
  attr :tasks_stream, :any, required: true
  attr :count, :integer, default: 0
  attr :selected_task_id, :string, default: nil
  attr :running_ids, :list, default: []
  attr :retry_ids, :list, default: []
  attr :running_started, :map, default: %{}
  attr :now_mono, :integer, default: 0
  attr :workload, :map, default: %{}
  attr :agents, :map, default: %{}
  attr :costs, :map, default: %{}
  attr :run_meta, :map, default: %{}

  defp column(assigns) do
    ~H"""
    <div
      class={[
        "flex-shrink-0 w-64 rounded-lg p-3 flex flex-col gap-2",
        human_column?(@status_id) && "bg-warning/10 border border-warning/30",
        not human_column?(@status_id) && "bg-base-200"
      ]}
      data-status={@status_id}
    >
      <h2 class={[
        "font-medium text-sm",
        human_column?(@status_id) && "text-warning",
        not human_column?(@status_id) && "text-base-content/80"
      ]}>
        {@title}
        <span class={[
          "badge badge-sm ml-1 font-mono",
          human_column?(@status_id) && "badge-warning",
          not human_column?(@status_id) && "badge-ghost"
        ]}>
          {@count}
        </span>
      </h2>
      <%= if @count == 0 do %>
        <p class="px-1 py-2 text-[10px] italic opacity-40">{column_empty_hint(@status_id)}</p>
      <% end %>
      <ul id={"col-#{@status_id}-tasks"} phx-update="stream" class="flex flex-col gap-2 min-h-[3rem]">
        <li :for={{dom_id, task} <- @tasks_stream} id={dom_id}>
          <% cost = Map.get(@costs, task.id) %>
          <% card = card_activity(task, @running_ids, @retry_ids) %>
          <div class={[
            "rounded-md p-2 text-sm border transition relative",
            @selected_task_id == task.id && "border-primary bg-base-100 ring-2 ring-primary/30",
            @selected_task_id != task.id &&
              "border-transparent bg-base-100/80 hover:border-base-300",
            card.running && "ring-2 ring-primary/50 bg-primary/5",
            card.retrying && "ring-2 ring-warning/40",
            card.wait_reason in [
              :approval,
              :budget_overage,
              :review,
              :ci_circuit,
              :changes_requested,
              :agent_question
            ] && "border-dashed border-warning/60"
          ]}>
            <button
              type="button"
              id={"task-#{task.id}"}
              phx-click="select_task"
              phx-value-id={task.id}
              class="w-full text-left focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary rounded-sm"
            >
              <div class="flex items-start justify-between gap-1">
                <div class="font-medium line-clamp-2 flex-1 min-w-0 break-words">{task.title}</div>
                <.card_status_chip
                  card={card}
                  task={task}
                  running_started={@running_started}
                  now_mono={@now_mono}
                />
              </div>
              <div class="mt-1.5 flex items-center justify-between gap-2">
                <.agent_badge
                  identity={AgentRegistry.identity(task.assignee, @agents)}
                  compact
                  workload={Map.get(@workload, task.assignee || "default")}
                />
                <div class="flex items-center gap-1 shrink-0">
                  <%= if Board.reviewer(task) do %>
                    <span class="text-[10px] opacity-60" title="Reviewer">{Board.reviewer(task)}</span>
                  <% end %>
                  <%= if @status_id == "review" do %>
                    <% glance = Board.review_glance(task, Map.get(@run_meta, task.id, %{})) %>
                    <span
                      class={[
                        "text-[10px] font-mono px-1 py-0.5 rounded",
                        glance == :has_pr && "bg-success/15 text-success",
                        glance == :no_pr && "bg-base-300/60 opacity-70"
                      ]}
                      title={
                        if glance == :has_pr,
                          do: "PR linked — open the card for Evidence",
                          else: "No PR linked yet"
                      }
                    >
                      {if glance == :has_pr, do: "PR", else: "no PR"}
                    </span>
                    <% ci = Board.review_ci(task) %>
                    <%= if ci.state != :na do %>
                      <.ci_evidence_chip state={ci.state} />
                    <% end %>
                  <% end %>
                  <span class="text-[10px] opacity-50">{type_label(task.type)}</span>
                </div>
              </div>

              <%= if cost && cost.record_count > 0 do %>
                <div class="mt-1">
                  <span class={[
                    "inline-block text-[10px] font-mono px-1.5 py-0.5 rounded badge-ghost",
                    cost.estimated && "opacity-70"
                  ]}>
                    {if cost.estimated, do: "est. ", else: ""}${cost.total_cost_usd}
                  </span>
                </div>
              <% end %>
            </button>

            <%= if card.wait_reason == :budget_overage do %>
              <div class="mt-2 flex gap-1">
                <button
                  type="button"
                  phx-click="approve_overage"
                  phx-value-id={task.id}
                  class="btn btn-primary btn-xs"
                >
                  Approve overage
                </button>
              </div>
            <% end %>
            <%= if card.wait_reason == :approval do %>
              <div class="mt-2 flex gap-1">
                <button
                  type="button"
                  phx-click="approve_task"
                  phx-value-id={task.id}
                  class="btn btn-primary btn-xs"
                >
                  Approve
                </button>
                <button
                  type="button"
                  phx-click="reject_task"
                  phx-value-id={task.id}
                  class="btn btn-ghost btn-xs"
                >
                  Reject
                </button>
              </div>
            <% end %>
          </div>
        </li>
      </ul>
    </div>
    """
  end

  attr :task_id, :string, default: nil
  attr :task, :map, default: nil
  attr :log, :string, default: ""
  attr :meta, :map, default: %{}
  attr :agents, :map, default: %{}
  attr :cost, :map, default: nil
  attr :running_started, :map, default: %{}
  attr :now_mono, :integer, default: 0
  attr :focused, :boolean, default: false

  defp run_console(assigns) do
    identity = panel_identity(assigns)
    assigns = assign(assigns, :identity, identity)

    ~H"""
    <div
      id="run-console"
      data-focused={to_string(@focused)}
      class={[
        "card bg-base-200 shadow-sm transition-shadow",
        @focused && "ring-1 ring-primary/40 shadow-md"
      ]}
    >
      <div class="card-body p-3 gap-2">
        <%= if @task do %>
          <%!-- Console chrome: agent, model, status, cost, task --%>
          <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1.5">
            <div class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
              <.agent_badge identity={@identity} />
              <span :if={@meta[:adapter]} class="text-[11px] font-mono opacity-60">
                {@meta[:adapter]}
              </span>
              <span :if={@meta[:model]} class="text-[11px] font-mono opacity-60">
                {@meta[:model]}
              </span>
              <span :if={@meta[:attempt]} class="text-[11px] opacity-50">
                · attempt {@meta[:attempt]}
              </span>
            </div>
            <div class="flex items-center gap-1.5 shrink-0">
              <.console_cost cost={@cost} />
              <.run_status_badge
                task={@task}
                running_started={@running_started}
                now_mono={@now_mono}
              />
              <button
                type="button"
                phx-click="clear_selection"
                class="btn btn-ghost btn-xs btn-square"
                title="Deselect"
              >
                <span class="text-base-content/30 hover:text-base-content text-sm leading-none">✕</span>
              </button>
            </div>
          </div>

          <p class="text-xs min-w-0 truncate">
            <span class="font-mono opacity-60">{@task.id}</span>
            <span class="opacity-40 mx-1">·</span>
            <span class="opacity-90">{@task.title}</span>
          </p>

          <%= if q = Board.pending_question(@task) do %>
            <.agent_question_panel task={@task} question={q} />
          <% else %>
            <.steer_panel
              :if={@task.status == "in_progress"}
              task={@task}
              adapter={@meta[:adapter] || @identity.adapter}
            />
          <% end %>

          <%= if @task.status == "review" do %>
            <% wait = Board.wait_reason(@task) %>
            <% changes_requested? = wait == :changes_requested %>
            <% evidence = Board.review_evidence(@task, @meta, @cost) %>
            <div class={[
              "rounded-md px-3 py-2 text-sm border",
              if(changes_requested?,
                do: "border-warning/50 bg-warning/10",
                else: "border-warning/30 bg-warning/5"
              )
            ]}>
              <p class="font-medium">
                {if changes_requested?, do: "Changes requested", else: "Awaiting human review"}
              </p>
              <p class="mt-0.5 opacity-80">
                <%= if changes_requested? do %>
                  A reviewer asked for changes on the PR. A follow-up run starts when review-resume is enabled; circuit shared with CI resume.
                <% else %>
                  <%= if evidence.pr_url do %>
                    Agent finished. Review the PR before merge, then mark done here.
                  <% else %>
                    Agent finished. No PR on the local board — check Evidence and the log/cost, then mark done.
                  <% end %>
                <% end %>
              </p>
              <%= if Board.reviewer(@task) do %>
                <p class="mt-1 text-xs opacity-70">Reviewer: {Board.reviewer(@task)}</p>
              <% end %>
              <.review_evidence_pack evidence={evidence} />
              <div class="mt-2 flex flex-wrap gap-2">
                <%= if evidence.pr_url do %>
                  <a
                    href={evidence.pr_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="btn btn-sm btn-outline"
                  >
                    Open PR
                  </a>
                <% end %>
                <button
                  type="button"
                  phx-click="complete_review"
                  phx-value-id={@task.id}
                  class="btn btn-sm btn-primary"
                >
                  Mark done
                </button>
              </div>
            </div>
          <% end %>

          <%= if @task.status == "failed" do %>
            <div class="rounded-md border border-error/30 bg-error/5 px-3 py-2 text-sm">
              <p class="font-medium text-error">Run failed</p>
              <p class="mt-0.5 opacity-80">
                Check the log below for the exit reason.
              </p>
            </div>
          <% end %>

          <%= if Board.wait_reason(@task) == :budget_overage do %>
            <div class="rounded-md border border-warning/40 bg-warning/10 px-3 py-2 text-sm">
              <p class="font-medium">Over budget</p>
              <p class="mt-0.5 opacity-80">
                Spend is at or above the cap. Approve once to allow the next spawn, or raise the cap.
              </p>
              <button
                type="button"
                phx-click="approve_overage"
                phx-value-id={@task.id}
                class="btn btn-primary btn-sm mt-2"
              >
                Approve overage
              </button>
            </div>
          <% end %>

          <%= if @task.status == Approval.pending_status() and
                   Board.wait_reason(@task) != :budget_overage do %>
            <div class="flex flex-wrap items-center gap-2">
              <button
                type="button"
                phx-click="approve_task"
                phx-value-id={@task.id}
                class="btn btn-primary btn-sm"
              >
                Approve
              </button>
              <button
                type="button"
                phx-click="reject_task"
                phx-value-id={@task.id}
                class="btn btn-ghost btn-sm"
              >
                Reject
              </button>
              <span class="text-xs opacity-60">Gate before dispatch</span>
            </div>
          <% end %>

          <div class="overflow-hidden rounded-lg border border-neutral bg-neutral text-neutral-content shadow-inner">
            <div class="flex items-center justify-between border-b border-neutral-content/10 px-3 py-1.5">
              <span class="font-mono text-[10px] text-neutral-content/50">run.log</span>
              <button
                id="run-log-copy"
                type="button"
                phx-hook="CopyLog"
                class="font-mono text-[10px] text-neutral-content/40 transition-colors hover:text-neutral-content/80"
              >
                Copy
              </button>
            </div>
            <div
              id="run-log"
              phx-hook="RunLogScroll"
              data-task-id={@task.id}
              data-attach={to_string(@focused)}
              role="log"
              aria-live="polite"
              aria-relevant="additions"
              data-terminal="true"
              class="max-h-[min(28rem,50vh)] overflow-y-auto p-3 font-mono text-[11px] leading-4"
            >
              <%= for {line, kind, status, cls} <- classify_log(@log) do %>
                <% label = stream_entry_label(kind, status) %>
                <div
                  data-stream-kind={kind}
                  data-stream-status={status}
                  data-stream-spacer={if is_nil(kind), do: "true"}
                  class={[
                    "grid grid-cols-[2.75rem_minmax(0,1fr)]",
                    cls
                  ]}
                >
                  <span
                    class="select-none border-r border-neutral-content/10 pr-2 text-right text-[9px] uppercase tracking-wider opacity-60"
                    aria-hidden="true"
                  >
                    {label}
                  </span>
                  <span class="min-w-0 whitespace-pre-wrap break-words pl-2 [overflow-wrap:anywhere]">{line}</span>
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <p class="text-sm font-medium">Run console</p>
          <p class="text-sm opacity-70">
            Select a card (<kbd class="font-mono text-xs rounded bg-base-300 px-1">j</kbd>/<kbd class="font-mono text-xs rounded bg-base-300 px-1">k</kbd>)
            for live agent output and per-ticket cost.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :evidence, :map, required: true

  defp review_evidence_pack(assigns) do
    ~H"""
    <div
      class="mt-2 rounded border border-base-300/70 bg-base-100/50 px-2.5 py-2"
      data-testid="review-evidence"
    >
      <div class="flex items-baseline justify-between gap-2">
        <p class="text-[11px] font-medium uppercase tracking-wide opacity-70">Evidence</p>
        <p class="text-[10px] opacity-50">Informational — merge on GitHub</p>
      </div>
      <dl class="mt-1.5 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs">
        <dt class="opacity-60">PR</dt>
        <dd class="min-w-0 font-mono break-all">
          <%= if @evidence.pr_url do %>
            <a
              href={@evidence.pr_url}
              target="_blank"
              rel="noopener noreferrer"
              class="link link-hover"
            >
              {@evidence.pr_url}
            </a>
          <% else %>
            <span class="opacity-50">N/A</span>
          <% end %>
        </dd>

        <dt class="opacity-60">Attempts</dt>
        <dd>
          <%= if is_integer(@evidence.attempts) do %>
            {@evidence.attempts}
          <% else %>
            <span class="opacity-50">—</span>
          <% end %>
        </dd>

        <dt class="opacity-60">Agent</dt>
        <dd class="min-w-0 truncate">
          <%= if @evidence.agent do %>
            {@evidence.agent}
          <% else %>
            <span class="opacity-50">—</span>
          <% end %>
        </dd>

        <dt class="opacity-60">Model</dt>
        <dd class="min-w-0 truncate font-mono">
          <%= if @evidence.model do %>
            {@evidence.model}
          <% else %>
            <span class="opacity-50">—</span>
          <% end %>
        </dd>

        <dt class="opacity-60">Cost</dt>
        <dd class="font-mono">
          <%= if @evidence.cost do %>
            {if @evidence.cost.estimated, do: "est. ", else: ""}${@evidence.cost.total_cost_usd}
          <% else %>
            <span class="opacity-50">no usage yet</span>
          <% end %>
        </dd>

        <dt class="opacity-60">CI</dt>
        <dd class="flex flex-wrap items-center gap-1.5">
          <.ci_evidence_chip state={@evidence.ci.state} />
          <%= if @evidence.ci.summary do %>
            <span class="opacity-70 min-w-0 truncate" title={@evidence.ci.summary}>
              {@evidence.ci.summary}
            </span>
          <% end %>
        </dd>

        <dt class="opacity-60">Age</dt>
        <dd>
          <%= if @evidence.age do %>
            <span title={DateTime.to_iso8601(@evidence.age.at)}>
              {format_evidence_age(@evidence.age.seconds)}
              <span class="opacity-50">({@evidence.age.label})</span>
            </span>
          <% else %>
            <span class="opacity-50">—</span>
          <% end %>
        </dd>
      </dl>
    </div>
    """
  end

  attr :state, :atom, required: true

  defp ci_evidence_chip(assigns) do
    {label, cls} =
      case assigns.state do
        :pass -> {"pass", "bg-success/20 text-success"}
        :fail -> {"fail", "bg-error/20 text-error"}
        :pending -> {"pending", "bg-warning/20 text-warning"}
        :unknown -> {"unknown", "bg-base-300/80 opacity-80"}
        _ -> {"N/A", "bg-base-300/60 opacity-60"}
      end

    assigns = assign(assigns, label: label, cls: cls)

    ~H"""
    <span
      class={["inline-block text-[10px] font-mono px-1.5 py-0.5 rounded uppercase", @cls]}
      data-testid="ci-chip"
      data-ci={@state}
    >
      {@label}
    </span>
    """
  end

  attr :cost, :map, default: nil

  defp console_cost(assigns) do
    ~H"""
    <%= if @cost && @cost.record_count > 0 do %>
      <span class="inline-flex items-center gap-1 text-[11px] font-mono">
        <span class="badge badge-ghost badge-sm font-mono gap-0.5">
          ${@cost.total_cost_usd}
        </span>
        <span :if={@cost.estimated} class="text-[10px] opacity-60">est.</span>
      </span>
    <% else %>
      <span class="text-[11px] opacity-50">no usage yet</span>
    <% end %>
    """
  end

  attr :identity, :map, required: true
  attr :compact, :boolean, default: false
  attr :workload, :integer, default: nil

  defp agent_badge(assigns) do
    mono = monogram(assigns.identity)
    assigns = assign(assigns, :mono, mono)

    ~H"""
    <div class={[
      "inline-flex items-center gap-1.5 min-w-0",
      @compact && "max-w-full"
    ]}>
      <span
        class="inline-flex items-center justify-center size-5 shrink-0 rounded-full bg-primary/15 text-[10px] font-semibold text-primary"
        aria-hidden="true"
      >
        {@mono}
      </span>
      <span class={[
        "font-medium truncate",
        @compact && "text-xs",
        !@compact && "text-sm"
      ]}>
        {@identity.display_name}
      </span>
      <%= if @identity.role do %>
        <span class="badge badge-ghost badge-xs shrink-0 opacity-80">{@identity.role}</span>
      <% end %>
      <%= if @workload && @workload > 1 do %>
        <span
          class="badge badge-neutral badge-xs shrink-0 font-mono"
          title="Open tasks for this agent"
        >
          {@workload}
        </span>
      <% end %>
    </div>
    """
  end

  attr :card, :map, required: true
  attr :task, :map, required: true
  attr :running_started, :map, default: %{}
  attr :now_mono, :integer, default: 0

  defp card_status_chip(assigns) do
    ~H"""
    <div class="flex items-center gap-1 shrink-0">
      <%= if @card.wait_reason == :agent_question do %>
        <span
          class={["badge badge-xs", wait_chip_class(:agent_question)]}
          title={Board.wait_reason_label(:agent_question)}
        >
          {Board.wait_reason_label(:agent_question)}
        </span>
      <% end %>
      <%= if @card.running do %>
        <span class="badge badge-primary badge-xs gap-1 font-mono">
          <span class="w-1.5 h-1.5 rounded-full bg-primary-content motion-safe:animate-pulse" />
          {format_elapsed(Map.get(@running_started, @task.id), @now_mono)}
        </span>
      <% else %>
        <%= if @card.retrying do %>
          <span class="badge badge-warning badge-xs">retry</span>
        <% else %>
          <%= if @card.wait_reason in [
                :approval,
                :budget_overage,
                :review,
                :ci_circuit,
                :changes_requested
              ] do %>
            <span
              class={[
                "badge badge-xs",
                wait_chip_class(@card.wait_reason)
              ]}
              title={Board.wait_reason_label(@card.wait_reason)}
            >
              {Board.wait_reason_label(@card.wait_reason)}
            </span>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp panel_identity(%{meta: meta, task: task, agents: agents}) when is_map(task) do
    if map_size(meta) > 0 do
      identity_from_meta(meta)
    else
      AgentRegistry.identity(task.assignee, agents)
    end
  end

  defp panel_identity(%{task: nil, agents: _}),
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

  defp column_empty_hint("todo"), do: "Task queue: dispatch or seed"
  defp column_empty_hint("pending_approval"), do: "No gates pending"
  defp column_empty_hint("in_progress"), do: "Nothing running"
  defp column_empty_hint("review"), do: "No work waiting for human review"
  defp column_empty_hint("done"), do: "No completed tasks"
  defp column_empty_hint("failed"), do: "No failures"
  defp column_empty_hint(_), do: "-"

  defp agent_count_label(0), do: "0 agents"
  defp agent_count_label(1), do: "1 agent"
  defp agent_count_label(n), do: "#{n} agents"

  defp busy_line(orchestrator, agents) do
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

  defp card_activity(task, running_ids, retry_ids) do
    id = task.id
    wait = Board.wait_reason(task)

    %{
      running: id in running_ids,
      retrying: id in retry_ids,
      wait_reason: wait,
      pending_approval: wait == :approval
    }
  end

  defp wait_chip_class(:ci_circuit), do: "badge-outline badge-error"
  defp wait_chip_class(:changes_requested), do: "badge-warning"
  defp wait_chip_class(:agent_question), do: "badge-outline badge-warning"
  defp wait_chip_class(_), do: "badge-outline badge-warning"

  defp answer_attrs_from_params(params) when is_map(params) do
    %{
      confirmed: params["confirmed"],
      value: params["value"],
      request_id: params["request_id"]
    }
  end

  attr :task, :map, required: true
  attr :question, :map, required: true

  defp agent_question_panel(assigns) do
    question = string_key_map(assigns.question)
    method = question["method"] || "input"
    prompt = question["prompt"] || ""
    request_id = question["request_id"] || question["id"] || ""
    options = question_options(question)

    assigns =
      assigns
      |> assign(:method, method)
      |> assign(:prompt, prompt)
      |> assign(:request_id, request_id)
      |> assign(:options, options)

    ~H"""
    <div
      id={"agent-question-#{@task.id}"}
      class="rounded-md border border-warning/40 bg-warning/5 px-3 py-2 text-sm"
    >
      <p class="font-medium">Agent asked a question</p>
      <p class="mt-0.5 opacity-90">{@prompt}</p>

      <div class="mt-2 flex flex-wrap items-center gap-2">
        <%= case @method do %>
          <% "confirm" -> %>
            <button
              type="button"
              phx-click="answer_agent_question"
              phx-value-id={@task.id}
              phx-value-request_id={@request_id}
              phx-value-confirmed="true"
              class="btn btn-sm btn-primary"
            >
              Yes
            </button>
            <button
              type="button"
              phx-click="answer_agent_question"
              phx-value-id={@task.id}
              phx-value-request_id={@request_id}
              phx-value-confirmed="false"
              class="btn btn-sm btn-outline"
            >
              No
            </button>
          <% "select" -> %>
            <button
              :for={{label, value} <- @options}
              type="button"
              phx-click="answer_agent_question"
              phx-value-id={@task.id}
              phx-value-request_id={@request_id}
              phx-value-value={value}
              class="btn btn-sm btn-outline"
            >
              {label}
            </button>
          <% _ -> %>
            <form phx-submit="answer_agent_question" class="flex flex-wrap items-center gap-2 w-full">
              <input type="hidden" name="task_id" value={@task.id} />
              <input type="hidden" name="request_id" value={@request_id} />
              <input
                type="text"
                name="value"
                required
                placeholder="Your answer"
                class="input input-sm input-bordered min-w-[12rem] flex-1"
              />
              <button type="submit" class="btn btn-sm btn-primary">Send</button>
            </form>
        <% end %>

        <button
          type="button"
          phx-click="cancel_agent_question"
          phx-value-id={@task.id}
          class="btn btn-ghost btn-sm"
        >
          Dismiss
        </button>
      </div>
      <p class="mt-1 text-[11px] opacity-60">One question at a time. Dismiss continues the run.</p>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :adapter, :string, default: nil

  defp steer_panel(assigns) do
    enabled? = assigns.adapter == "pi_rpc"
    assigns = assign(assigns, :enabled?, enabled?)

    ~H"""
    <div id={"steer-run-#{@task.id}"} class="rounded-md border border-base-300 px-3 py-2 text-sm">
      <form phx-submit="steer_run" class="flex flex-wrap items-center gap-2">
        <input type="hidden" name="task_id" value={@task.id} />
        <input
          type="text"
          name="message"
          required={@enabled?}
          disabled={not @enabled?}
          placeholder={if @enabled?, do: "Steer this run…", else: "Steer is Pi RPC on a live run"}
          class="input input-sm input-bordered min-w-[12rem] flex-1"
        />
        <button type="submit" class="btn btn-sm btn-outline" disabled={not @enabled?}>
          Steer
        </button>
      </form>
      <p :if={not @enabled?} class="mt-1 text-[11px] opacity-60">
        Steer is Pi RPC on a live run.
      </p>
    </div>
    """
  end

  defp question_options(%{"options" => list}) when is_list(list),
    do: Enum.map(list, &option_pair/1)

  defp question_options(_), do: []

  defp string_key_map(map) when is_map(map) do
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

  defp review_badge(task) do
    case Board.wait_reason(task) do
      :changes_requested -> {"Changes requested", "badge-warning"}
      :ci_circuit -> {"CI retries exhausted", "badge-error"}
      _ -> {"Needs review", "badge-warning"}
    end
  end

  defp human_column?(status) when status in ["pending_approval", "review"], do: true
  defp human_column?(_), do: false

  defp format_elapsed(nil, _now), do: "…"

  defp format_elapsed(started_mono, now) when is_integer(started_mono) and is_integer(now) do
    sec = max(div(now - started_mono, 1000), 0)
    format_duration(sec)
  end

  defp format_elapsed(_, _), do: "…"

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

  defp column_label("todo"), do: "Todo"
  defp column_label("pending_approval"), do: "Needs approval"
  defp column_label("in_progress"), do: "In progress"
  defp column_label("review"), do: "Review"
  defp column_label("done"), do: "Done"
  defp column_label("failed"), do: "Failed"

  defp column_label(other) when is_binary(other) do
    other
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp column_label(_), do: "Column"

  defp type_label("code"), do: "Code"
  defp type_label("research"), do: "Research"
  defp type_label("docs"), do: "Docs"
  defp type_label("documentation"), do: "Docs"
  defp type_label("test"), do: "Test"
  defp type_label("review"), do: "Review"
  defp type_label(nil), do: "Task"
  defp type_label(""), do: "Task"

  defp type_label(other) when is_binary(other) do
    other
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp type_label(_), do: "Task"

  defp approval_mode_label(o) when is_map(o) do
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

  defp orchestrator_idle?(o) when is_map(o) do
    Map.get(o, :running, 0) == 0 and
      Map.get(o, :claimed, 0) == 0 and
      Map.get(o, :retrying, 0) == 0
  end

  defp orchestrator_idle?(_), do: true

  defp session_cost_line(o) when is_map(o) do
    case Map.get(o, :session_cost) do
      %{record_count: n, total_cost_usd: usd, estimated: true} when is_integer(n) and n > 0 ->
        "$#{usd} est."

      %{record_count: n, total_cost_usd: usd} when is_integer(n) and n > 0 ->
        "$#{usd}"

      _ ->
        nil
    end
  end

  defp session_cost_line(_), do: nil

  defp last_poll_label(o, now_mono) when is_map(o) and is_integer(now_mono) do
    case Map.get(o, :last_tick_mono_ms) do
      t when is_integer(t) ->
        sec = max(div(now_mono - t, 1000), 0)
        format_elapsed_ago(sec)

      _ ->
        nil
    end
  end

  defp last_poll_label(_, _), do: nil

  defp format_elapsed_ago(sec) when sec < 5, do: "just now"
  defp format_elapsed_ago(sec) when sec < 60, do: "#{sec}s ago"
  defp format_elapsed_ago(sec) when sec < 3600, do: "#{div(sec, 60)}m ago"
  defp format_elapsed_ago(sec), do: "#{div(sec, 3600)}h ago"

  attr :task, :map, required: true
  attr :running_started, :map, default: %{}
  attr :now_mono, :integer, default: 0

  defp run_status_badge(assigns) do
    task = assigns.task
    running_started = assigns.running_started
    running? = Map.has_key?(running_started, task.id)
    status = task.status

    {label, cls} =
      cond do
        running? -> {"Running", "badge-primary gap-1"}
        status == "failed" -> {"Failed", "badge-error"}
        status == "done" -> {"Done", "badge-success"}
        status == Approval.pending_status() -> {"Needs approval", "badge-warning"}
        status == "review" -> review_badge(task)
        true -> {String.capitalize(status), "badge-ghost"}
      end

    duration =
      if running? do
        duration_label(running_started, task.id, assigns.now_mono)
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:cls, cls)
      |> assign(:running, running?)
      |> assign(:duration, duration)

    ~H"""
    <span class={["badge badge-sm shrink-0", @cls]}>
      <%= if @running do %>
        <span class="w-1.5 h-1.5 rounded-full bg-primary-content motion-safe:animate-pulse" />
      <% end %>
      {@label}
      <%= if @duration do %>
        <span class="font-mono opacity-70">· {@duration}</span>
      <% end %>
    </span>
    """
  end

  defp duration_label(running_started, task_id, now_mono)
       when is_map_key(running_started, task_id) and is_integer(now_mono) do
    started = Map.get(running_started, task_id)
    sec = max(div(now_mono - started, 1000), 0)
    format_duration(sec)
  end

  defp duration_label(_, _, _), do: nil

  defp format_evidence_age(sec) when is_integer(sec) and sec >= 0 do
    format_duration(sec)
  end

  defp format_evidence_age(_), do: "—"

  defp classify_log(log) when is_binary(log) do
    # ponytail: stable projection prefixes are the restore boundary while RunLog is text-only.
    log
    |> String.split("\n")
    |> compact_log_spacing()
    |> Enum.map(&classify_log_line/1)
  end

  defp classify_log(_), do: []

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

  defp stream_entry_label("tool_start", _), do: "tool"
  defp stream_entry_label("tool_end", "error"), do: "fail"
  defp stream_entry_label("tool_end", _), do: "done"
  defp stream_entry_label("run_marker", _), do: "run"
  defp stream_entry_label(_, _), do: ""

  defp monogram(%{display_name: name}) when is_binary(name) and name != "" do
    name
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "?"
      c -> String.upcase(c)
    end
  end

  defp monogram(_), do: "?"
end
