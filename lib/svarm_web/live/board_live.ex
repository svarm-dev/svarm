defmodule SvarmWeb.BoardLive do
  @moduledoc "Real-time blended team board and agent run log."
  use SvarmWeb, :live_view

  alias Svarm.{AgentRegistry, AgentRunner, Approval, Board, Events, Usage}

  @max_log_lines 400

  @impl true
  def mount(_params, _session, socket) do
    agents = AgentRunner.load_agents()

    socket =
      socket
      |> assign(:columns, Board.group_by_status([]))
      |> assign(:column_ids, Board.column_ids())
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
      |> assign(:dev_routes, Application.get_env(:svarm, :dev_routes, false))
      |> assign(:demo_routes, Svarm.Demo.routes_enabled?())
      |> assign(:checklist, Svarm.Board.instance_status())
      |> assign(:connected, false)

    socket =
      if connected?(socket) do
        Events.subscribe()
        Phoenix.PubSub.subscribe(Svarm.PubSub, "approvals")

        socket
        |> load_board()
        |> assign(:connected, true)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"task" => id}, _uri, socket) when is_binary(id) and id != "" do
    {:noreply, select_task(socket, id, patch: false)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :selected_task_id, nil)}
  end

  @impl true
  def handle_event("select_task", %{"id" => id}, socket) do
    {:noreply, select_task(socket, id)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, clear_selection(socket)}
  end

  def handle_event("approve_task", %{"id" => id}, socket) do
    case Approval.approve(id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Approved #{id}")
         |> load_board()
         |> then(fn s -> if s.assigns.selected_task_id == id, do: select_task(s, id), else: s end)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Approval.flash_error(reason))}
    end
  end

  def handle_event("reject_task", %{"id" => id}, socket) do
    case Approval.reject(id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Rejected #{id}")
         |> load_board()
         |> then(fn s -> if s.assigns.selected_task_id == id, do: select_task(s, id), else: s end)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Approval.flash_error(reason))}
    end
  end

  def handle_event("board_keydown", %{"key" => key}, socket) do
    {:noreply, handle_board_key(socket, key)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_board(socket)}
  end

  def handle_event("board_tick", _params, socket) do
    {:noreply, assign(socket, :now_mono, System.monotonic_time(:millisecond))}
  end

  @impl true
  def handle_info({:task_updated, task}, socket) do
    socket =
      socket
      |> update_task_in_columns(task)
      |> maybe_append_status_line(task)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:tasks_snapshot, tasks}, socket) do
    {:noreply, put_columns(socket, tasks)}
  end

  @impl true
  def handle_info({:orchestrator_status, status}, socket) do
    session_cost = Usage.session_cost_summary()
    status = Map.put(status, :session_cost, session_cost)

    socket =
      socket
      |> assign(:orchestrator, status)
      |> assign(:running_started, Map.get(status, :running_started, %{}))

    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_started, task_id, meta}, socket) do
    identity = identity_from_meta(meta)
    label = run_started_label(identity, meta)

    started_mono = meta[:started_mono_ms] || System.monotonic_time(:millisecond)

    socket =
      socket
      |> assign(:run_meta, Map.put(socket.assigns.run_meta, task_id, meta))
      |> assign(:running_started, Map.put(socket.assigns.running_started, task_id, started_mono))
      |> append_log(task_id, "--- #{label} ---\n")

    socket =
      if is_nil(socket.assigns.selected_task_id) do
        select_task(socket, task_id, patch: false)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_line, task_id, line}, socket) do
    {:noreply, append_log(socket, task_id, line)}
  end

  @impl true
  def handle_info({:run_finished, task_id, exit_code}, socket) do
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
      |> append_log(
        task_id,
        "\n--- run finished (exit #{exit_code}) ---\n"
      )

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
            <h1 class="text-2xl font-semibold tracking-tight">Team Board</h1>
            <p class="text-sm opacity-70">Your AI teammates, governed</p>
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
          <% not @connected -> %>
            <.board_skeleton />
          <% @task_count == 0 -> %>
            <.board_empty demo_routes={@demo_routes} checklist={@checklist} />
          <% true -> %>
            <.demo_bridge_banner columns={@columns} checklist={@checklist} />
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
                  tasks={Map.get(@columns, col, [])}
                  selected_task_id={@selected_task_id}
                  running_ids={Map.get(@orchestrator, :running_ids, [])}
                  retry_ids={Map.get(@orchestrator, :retry_ids, [])}
                  running_started={@running_started}
                  now_mono={@now_mono}
                  workload={@workload}
                  agents={@agents}
                  costs={@costs}
                />
              <% end %>
            </div>

            <.run_panel
              task_id={@selected_task_id}
              task={selected_task(@columns, @selected_task_id)}
              log={Map.get(@run_logs, @selected_task_id, "")}
              meta={Map.get(@run_meta, @selected_task_id, %{})}
              agents={@agents}
              cost={Map.get(@task_costs, @selected_task_id)}
              running_started={@running_started}
              now_mono={@now_mono}
            />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp load_board(socket) do
    tasks = Board.list_tasks()
    socket = put_columns(socket, tasks)
    costs = compute_costs(tasks)
    orchestrator = Board.orchestrator_status()

    # Attach session cost for the bar
    session_cost = Usage.session_cost_summary()
    orchestrator = Map.put(orchestrator, :session_cost, session_cost)

    socket
    |> assign(:costs, costs)
    |> assign(:orchestrator, orchestrator)
    |> assign(:workload, Board.counts_by_assignee(tasks))
    |> assign(:running_started, Map.get(orchestrator, :running_started, %{}))
    |> restore_run_logs(tasks)
  end

  defp compute_costs(tasks) do
    tasks
    |> Enum.map(fn task ->
      case Usage.task_cost_summary(task.id) do
        nil -> nil
        summary -> {task.id, summary}
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp put_columns(socket, tasks) do
    costs = compute_costs(tasks)

    socket
    |> assign(:column_ids, Board.column_ids())
    |> assign(:columns, Board.group_by_status(tasks))
    |> assign(:task_count, length(tasks))
    |> assign(:costs, costs)
    |> assign(:workload, Board.counts_by_assignee(tasks))
  end

  defp update_task_in_columns(socket, task) do
    cols = socket.assigns.columns

    cols =
      cols
      |> Enum.map(fn {status, list} ->
        {status, Enum.reject(list, &(&1.id == task.id))}
      end)
      |> Map.new()

    status = task.status
    cols = Map.update(cols, status, [task], fn list -> list ++ [task] end)

    task_count =
      cols
      |> Map.values()
      |> List.flatten()
      |> length()

    socket
    |> assign(:columns, cols)
    |> assign(:task_count, task_count)
  end

  defp maybe_append_status_line(socket, %{id: id, status: status}) do
    append_log(socket, id, "[board] status → #{status}\n")
  end

  defp restore_run_logs(socket, tasks) do
    logs =
      Enum.reduce(tasks, socket.assigns.run_logs, fn task, acc ->
        case Svarm.RunLog.get(task.id) do
          "" -> acc
          text -> Map.put(acc, task.id, text)
        end
      end)

    assign(socket, :run_logs, logs)
  end

  defp append_log(socket, task_id, chunk) when is_binary(task_id) do
    Svarm.RunLog.append(task_id, chunk)

    logs = socket.assigns.run_logs
    prev = Map.get(logs, task_id)
    text = if prev, do: prev <> chunk, else: chunk
    assign(socket, :run_logs, Map.put(logs, task_id, trim_log(text)))
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

  defp selected_task(_columns, nil), do: nil

  defp selected_task(columns, id) do
    columns
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&(&1.id == id))
  end

  attr :demo_routes, :boolean, default: false
  attr :checklist, :map, default: %{}

  defp board_skeleton(assigns) do
    ~H"""
    <div class="space-y-6 animate-pulse">
      <div class="rounded-lg border border-base-300 bg-base-200/60 px-4 py-3">
        <div class="flex flex-wrap gap-4">
          <div>
            <div class="h-3 w-16 rounded bg-base-300 mb-1" />
            <div class="h-5 w-8 rounded bg-base-300" />
          </div>
          <div>
            <div class="h-3 w-16 rounded bg-base-300 mb-1" />
            <div class="h-5 w-8 rounded bg-base-300" />
          </div>
          <div>
            <div class="h-3 w-20 rounded bg-base-300 mb-1" />
            <div class="h-5 w-12 rounded bg-base-300" />
          </div>
        </div>
      </div>
      <div class="flex gap-4 overflow-x-auto pb-4">
        <%= for _ <- 1..5 do %>
          <div class="flex-shrink-0 w-64 bg-base-200 rounded-lg p-3">
            <div class="h-4 w-16 rounded bg-base-300 mb-3" />
            <div class="space-y-2">
              <div class="h-14 rounded-md bg-base-300/50" />
              <div class="h-14 rounded-md bg-base-300/50" />
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :columns, :map, required: true
  attr :checklist, :map, default: %{}

  defp demo_bridge_banner(assigns) do
    has_demo_tasks =
      assigns.columns
      |> Map.values()
      |> List.flatten()
      |> Enum.any?(fn t ->
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
        workflow_path: Map.get(c, :workflow_path) || "—",
        tracker_label: Map.get(c, :tracker_label) || "local",
        agent_count: Map.get(c, :agent_count) || 0,
        approval_mode: Map.get(c, :approval_mode) || "untrusted",
        approvals_auth?: Map.get(c, :approvals_auth?, false)
      )

    ~H"""
    <section
      class="rounded-lg border border-base-300 bg-base-200/70 px-6 py-8 sm:px-8"
      aria-labelledby="board-empty-title"
    >
      <h2 id="board-empty-title" class="text-lg font-semibold tracking-tight">
        All quiet — no tickets yet
      </h2>
      <p class="mt-2 max-w-2xl text-sm opacity-80">
        This board is the live view of your blended team. Tickets move through columns as agents
        claim work; select a card for streamed output and per-ticket cost.
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
            Point WORKFLOW.md at your tracker and open eligible issues — or run
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
      <%= if Map.get(@orchestrator, :running, 0) > 0 do %>
        <p class="text-sm font-medium flex items-center gap-2">
          <span class="inline-block w-2 h-2 rounded-full bg-primary motion-safe:animate-pulse" />
          {busy_line(@orchestrator, @agents)}
        </p>
      <% end %>

      <%= if @idle? do %>
        <p class="text-sm opacity-60 rounded-lg border border-base-300 bg-base-200/60 px-3 py-2">
          Orchestrator idle — nothing running
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
  attr :tasks, :list, required: true
  attr :selected_task_id, :string, default: nil
  attr :running_ids, :list, default: []
  attr :retry_ids, :list, default: []
  attr :running_started, :map, default: %{}
  attr :now_mono, :integer, default: 0
  attr :workload, :map, default: %{}
  attr :agents, :map, default: %{}
  attr :costs, :map, default: %{}

  defp column(assigns) do
    ~H"""
    <div
      class="flex-shrink-0 w-64 bg-base-200 rounded-lg p-3 flex flex-col gap-2"
      data-status={@status_id}
    >
      <h2 class="font-medium text-sm text-base-content/80">
        {@title}
        <span class="badge badge-sm badge-ghost ml-1 font-mono">{length(@tasks)}</span>
      </h2>
      <ul class="flex flex-col gap-2 min-h-[3rem]">
        <%= if @tasks == [] do %>
          <li class="px-1 py-2 text-[10px] italic opacity-40">{column_empty_hint(@status_id)}</li>
        <% end %>
        <%= for task <- @tasks do %>
          <% cost = Map.get(@costs, task.id) %>
          <% card = card_activity(task, @running_ids, @retry_ids) %>
          <li>
            <div class={[
              "rounded-md p-2 text-sm border transition relative",
              @selected_task_id == task.id && "border-primary bg-base-100 ring-2 ring-primary/30",
              @selected_task_id != task.id &&
                "border-transparent bg-base-100/80 hover:border-base-300",
              card.running && "ring-2 ring-primary/50 bg-primary/5",
              card.retrying && "ring-2 ring-warning/40",
              card.pending_approval && "border-dashed border-warning/60"
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
                  <span class="text-[10px] opacity-50 shrink-0">{type_label(task.type)}</span>
                </div>

                <%= if cost && cost.record_count > 0 do %>
                  <div class="mt-1">
                    <span class={[
                      "inline-block text-[10px] font-mono px-1.5 py-0.5 rounded badge-ghost",
                      cost.estimated && "opacity-70"
                    ]}>
                      {if cost.estimated, do: "est. ", else: ""}$#{cost.total_cost_usd}
                    </span>
                  </div>
                <% end %>
              </button>

              <%= if card.pending_approval and not demo_task?(task) do %>
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
        <% end %>
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

  defp run_panel(assigns) do
    identity = panel_identity(assigns)
    assigns = assign(assigns, :identity, identity)

    ~H"""
    <div class="card bg-base-200 shadow-sm">
      <div class="card-body p-4 gap-3">
        <%= if @task do %>
          <div class="flex items-center justify-between gap-2">
            <.agent_badge identity={@identity} />
            <div class="flex items-center gap-1">
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

          <p class="text-sm">
            <span class="font-mono text-xs opacity-70">{@task.id}</span> — {@task.title}
          </p>

          <%= if map_size(@meta) > 0 do %>
            <p class="text-xs opacity-60 flex flex-wrap gap-x-3 gap-y-1">
              <span>Attempt {@meta[:attempt] || "?"}</span>
              <span :if={@meta[:adapter]}>{@meta[:adapter]}</span>
              <span :if={@meta[:model]}>{@meta[:model]}</span>
            </p>
          <% end %>

          <.cost_breakdown cost={@cost} />

          <%= if @task.status == "failed" do %>
            <div class="rounded-md border border-error/30 bg-error/5 px-3 py-2 text-sm">
              <p class="font-medium text-error">Run failed</p>
              <p class="mt-0.5 opacity-80">
                Check the log below for the exit reason.
              </p>
            </div>
          <% end %>

          <%= if @task.status == Approval.pending_status() and not demo_task?(@task) do %>
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

          <div class="rounded-lg border border-base-300 bg-base-300/40">
            <div class="flex items-center justify-between px-3 py-1.5 border-b border-base-300">
              <span class="text-[10px] font-medium opacity-50 uppercase tracking-wide">Output</span>
              <button
                id="run-log-copy"
                type="button"
                phx-hook="CopyLog"
                class="text-[10px] font-medium opacity-40 hover:opacity-80 transition-opacity"
              >
                Copy
              </button>
            </div>
            <div
              id="run-log"
              phx-hook="RunLogScroll"
              role="log"
              aria-live="polite"
              aria-relevant="additions"
              class="p-3 text-xs font-mono max-h-96 overflow-y-auto whitespace-pre-wrap break-all space-y-0.5"
            >
              <%= for {line, cls} <- classify_log(@log) do %>
                <div class={cls}>{line}</div>
              <% end %>
            </div>
          </div>
        <% else %>
          <p class="text-sm font-medium">Run detail</p>
          <p class="text-sm opacity-70">
            Select a card (<kbd class="font-mono text-xs rounded bg-base-300 px-1">j</kbd>/<kbd class="font-mono text-xs rounded bg-base-300 px-1">k</kbd>)
            for live agent output and per-ticket cost.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :cost, :map, default: nil

  defp cost_breakdown(assigns) do
    ~H"""
    <%= if @cost && @cost.record_count > 0 do %>
      <div class="mt-1 flex flex-wrap items-center gap-2 text-xs">
        <div class="badge badge-ghost gap-1 font-mono">
          ${@cost.total_cost_usd}
        </div>
        <div :if={@cost.estimated} class="badge badge-ghost text-[10px] opacity-70">
          estimated
        </div>

        <%= for {{source, provider, model}, source_cost} <- @cost.breakdown do %>
          <div class="badge badge-ghost gap-1 text-[10px] font-mono opacity-80">
            {source} · {model} ${Float.round(source_cost, 4)}
          </div>
        <% end %>
      </div>
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
    <%= if @card.running do %>
      <span class="badge badge-primary badge-xs gap-1 shrink-0 font-mono">
        <span class="w-1.5 h-1.5 rounded-full bg-primary-content motion-safe:animate-pulse" />
        {format_elapsed(Map.get(@running_started, @task.id), @now_mono)}
      </span>
    <% else %>
      <%= if @card.retrying do %>
        <span class="badge badge-warning badge-xs shrink-0">retry</span>
      <% else %>
        <%= if @card.pending_approval do %>
          <span
            class="badge badge-warning badge-outline badge-xs shrink-0"
            title="Awaiting human gate approval"
          >approval</span>
        <% end %>
      <% end %>
    <% end %>
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

  defp run_started_label(identity, meta) do
    attempt = meta[:attempt] || "?"
    role = if identity.role, do: " (#{identity.role})", else: ""
    "#{identity.display_name}#{role} started · attempt #{attempt}"
  end

  defp column_empty_hint("todo"), do: "Task queue — dispatch or seed"
  defp column_empty_hint("pending_approval"), do: "No gates pending"
  defp column_empty_hint("in_progress"), do: "Nothing running"
  defp column_empty_hint("review"), do: "No completed work to review"
  defp column_empty_hint("done"), do: "No completed tasks"
  defp column_empty_hint("failed"), do: "No failures"
  defp column_empty_hint(_), do: "—"

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
    status = task.status

    %{
      running: id in running_ids,
      retrying: id in retry_ids,
      pending_approval: status == Approval.pending_status()
    }
  end

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
    costs = fetch_task_cost(id, socket.assigns.task_costs)

    socket =
      socket
      |> assign(:selected_task_id, id)
      |> assign(:task_costs, costs)

    if patch? do
      push_patch(socket, to: ~p"/board?#{[task: id]}", replace: true)
    else
      socket
    end
  end

  defp clear_selection(socket) do
    socket
    |> assign(:selected_task_id, nil)
    |> push_patch(to: ~p"/board", replace: true)
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
    ids = task_ids_in_order(socket.assigns.columns, socket.assigns.column_ids)

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

  defp task_ids_in_order(columns, column_ids) do
    Enum.flat_map(column_ids, fn col ->
      columns
      |> Map.get(col, [])
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
        status == Approval.pending_status() -> {"Pending", "badge-warning"}
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

  defp classify_log(log) when is_binary(log) do
    log
    |> String.split("\n")
    |> Enum.map(fn
      "" ->
        {"", ""}

      line ->
        cls =
          cond do
            String.starts_with?(line, "--- ") ->
              "opacity-40 italic"

            String.starts_with?(line, "[board]") ->
              "opacity-40 text-[10px]"

            String.contains?(line, "error") or String.contains?(line, "Error") ->
              "text-error font-medium"

            String.contains?(line, "warning") or String.contains?(line, "Warning") ->
              "text-warning"

            true ->
              ""
          end

        {line, cls}
    end)
  end

  defp classify_log(_), do: []

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

  defp demo_task?(%{assignee: assignee}) when is_binary(assignee),
    do: String.starts_with?(assignee, "demo_")

  defp demo_task?(_), do: false
end
