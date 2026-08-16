defmodule SvarmWeb.DashboardLive do
  @moduledoc """
  Operational dashboard for team leads: who's doing what, is the queue moving,
  what did it cost. Read-only; task detail lives at /board.
  """
  use SvarmWeb, :live_view

  alias Svarm.{Board, Dashboard, Events}

  # Full snapshot reloads are expensive; coalesce PubSub storms (status ticks,
  # multi-agent task_updated) into one reload.
  @reload_coalesce_ms 750

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:reload_timer, nil)
      |> then(fn s ->
        if connected?(s) do
          Events.subscribe()
          load_dashboard(s)
        else
          assign(s,
            snapshot: empty_snapshot(),
            time_window: "session",
            window_cost: empty_window_cost(),
            error: nil,
            connected: false,
            now_mono: System.monotonic_time(:millisecond)
          )
        end
      end)

    {:ok, socket}
  end

  @impl true
  def handle_event("set_window", %{"window" => window}, socket) do
    cost = Dashboard.cost_for_window(window)

    {:noreply,
     socket
     |> assign(:time_window, window)
     |> assign(:window_cost, cost)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> cancel_coalesced_reload() |> load_dashboard()}
  end

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    {:noreply, schedule_coalesced_reload(socket)}
  end

  def handle_info({:tasks_snapshot, _tasks}, socket) do
    {:noreply, schedule_coalesced_reload(socket)}
  end

  def handle_info({:orchestrator_status, status}, socket) do
    # Lightweight: apply status to snapshot immediately; coalesce full reload
    # so agent roster / distribution catch up without per-tick DB work.
    snapshot = Map.put(socket.assigns.snapshot, :orchestrator, status)

    socket =
      socket
      |> assign(:snapshot, snapshot)
      |> assign(:now_mono, System.monotonic_time(:millisecond))
      |> schedule_coalesced_reload()

    {:noreply, socket}
  end

  def handle_info({:run_finished, _task_id, _exit_code}, socket) do
    {:noreply, schedule_coalesced_reload(socket)}
  end

  def handle_info(:coalesced_dashboard_reload, socket) do
    socket =
      socket
      |> assign(:reload_timer, nil)
      |> load_dashboard()

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp schedule_coalesced_reload(socket) do
    case socket.assigns[:reload_timer] do
      ref when is_reference(ref) ->
        socket

      _ ->
        ref = Process.send_after(self(), :coalesced_dashboard_reload, @reload_coalesce_ms)
        assign(socket, :reload_timer, ref)
    end
  end

  defp cancel_coalesced_reload(socket) do
    case socket.assigns[:reload_timer] do
      ref when is_reference(ref) ->
        Process.cancel_timer(ref)
        assign(socket, :reload_timer, nil)

      _ ->
        socket
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={:dashboard}>
      <div class="max-w-5xl mx-auto space-y-5">
        <div class="flex items-start justify-between gap-4">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Dashboard</h1>
            <p class="text-sm opacity-70">Work waiting on humans, spend, and who's live</p>
          </div>
          <button type="button" phx-click="refresh" class="btn btn-sm btn-ghost shrink-0">
            Refresh
          </button>
        </div>

        <%= if @error do %>
          <.error_card error={@error} />
        <% else %>
          <%= if not @connected do %>
            <.loading_skeleton />
          <% else %>
            <.system_status
              orchestrator={@snapshot.orchestrator}
              human_wait={@snapshot.human_wait}
              now_mono={@now_mono}
            />

            <.human_wait_strip summary={@snapshot.human_wait} />

            <.spend_card cost={@window_cost} window={@time_window} />

            <.queue_strip
              task_distribution={@snapshot.task_distribution}
              orchestrator={@snapshot.orchestrator}
            />

            <div class="grid grid-cols-1 lg:grid-cols-2 gap-5">
              <.agent_roster agents={@snapshot.agent_roster} />
              <.task_breakdown distribution={@snapshot.task_distribution} />
            </div>

            <.recent_runs runs={@snapshot.recent_runs} />
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # -- Components --

  defp loading_skeleton(assigns) do
    ~H"""
    <div class="space-y-5 animate-pulse">
      <div class="h-5 w-64 rounded bg-base-300" />
      <div class="rounded-lg border border-base-300 bg-base-200/60 h-16" />
      <div class="rounded-lg border border-base-300 bg-base-200/60 h-24" />
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-5">
        <div class="rounded-lg border border-base-300 bg-base-200/60 p-4 h-48" />
        <div class="rounded-lg border border-base-300 bg-base-200/60 p-4 h-48" />
      </div>
    </div>
    """
  end

  attr :error, :string, required: true

  defp error_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-error/30 bg-error/5 px-6 py-8 text-center">
      <p class="font-medium text-error">Failed to load dashboard</p>
      <p class="mt-1 text-sm opacity-80">{@error}</p>
      <button type="button" phx-click="refresh" class="btn btn-sm btn-outline mt-4">
        Retry
      </button>
    </div>
    """
  end

  attr :orchestrator, :map, required: true
  attr :human_wait, :map, required: true
  attr :now_mono, :integer, required: true

  defp system_status(assigns) do
    o = assigns.orchestrator || %{}
    running = Map.get(o, :running, 0)
    wait_total = Map.get(assigns.human_wait || %{}, :total, 0)
    last_poll = last_poll_label(o, assigns.now_mono)

    assigns =
      assign(assigns,
        running: running,
        wait_total: wait_total,
        last_poll: last_poll,
        live?: running > 0
      )

    ~H"""
    <p class="text-xs opacity-70 flex flex-wrap items-center gap-x-1.5 gap-y-0.5">
      <span class={[
        "inline-flex items-center gap-1 font-medium",
        @live? && "text-primary",
        !@live? && "text-base-content/70"
      ]}>
        <span class={[
          "size-1.5 rounded-full",
          @live? && "bg-primary motion-safe:animate-pulse",
          !@live? && "bg-base-content/30"
        ]} />
        {if @live?, do: "#{@running} running", else: "Idle"}
      </span>
      <%= if @last_poll do %>
        <span aria-hidden="true">·</span>
        <span>last poll {@last_poll}</span>
      <% end %>
      <span aria-hidden="true">·</span>
      <span>
        {if @wait_total > 0,
          do: "#{@wait_total} waiting on humans",
          else: "nothing waiting on humans"}
      </span>
    </p>
    """
  end

  attr :summary, :map, required: true

  defp human_wait_strip(assigns) do
    s = assigns.summary || Board.human_wait_summary([])
    assigns = assign(assigns, :summary, s)

    ~H"""
    <div class={[
      "rounded-lg border px-4 py-3 flex flex-wrap items-center justify-between gap-3",
      @summary.total > 0 && "border-warning/30 bg-warning/5",
      @summary.total == 0 && "border-base-300 bg-base-200/60"
    ]}>
      <div>
        <p class="text-sm font-semibold">Waiting on humans</p>
        <p class="text-xs opacity-70 mt-0.5">
          Approvals {@summary.pending_approval}
          <%= if Map.get(@summary, :budget_overage, 0) > 0 do %>
            · Over budget {@summary.budget_overage}
          <% end %>
          · Review {@summary.review} · Total {@summary.total}
        </p>
      </div>
      <div class="flex gap-2">
        <%= if @summary.pending_approval > 0 do %>
          <a href={~p"/approvals"} class="btn btn-xs btn-primary">Approvals</a>
          <a href={~p"/board"} class="btn btn-xs btn-outline">Board</a>
        <% else %>
          <%= if @summary.review > 0 do %>
            <a href={~p"/board"} class="btn btn-xs btn-primary">Open board</a>
          <% else %>
            <a href={~p"/board"} class="btn btn-xs btn-outline">Board</a>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :cost, :map, required: true
  attr :window, :string, required: true

  defp spend_card(assigns) do
    cost = assigns.cost || empty_window_cost()
    tokens = (cost[:prompt_tokens] || 0) + (cost[:completion_tokens] || 0)
    usd = cost[:total_cost_usd] || 0.0
    estimated? = cost[:estimated] == true

    assigns =
      assign(assigns,
        usd: usd,
        tokens: tokens,
        estimated?: estimated?,
        records: cost[:record_count] || 0
      )

    ~H"""
    <section class="rounded-lg border border-base-300 bg-base-200/60 p-4">
      <div class="flex flex-wrap items-center justify-between gap-3 mb-3">
        <div>
          <h2 class="text-sm font-semibold">Spend</h2>
          <p class="text-xs opacity-60 mt-0.5">{window_caption(@window)}</p>
        </div>
        <.time_window_picker window={@window} />
      </div>
      <div class="flex flex-wrap items-baseline gap-x-6 gap-y-2">
        <div>
          <p class="text-xs opacity-60">Cost</p>
          <p class="text-xl font-semibold font-mono mt-0.5">
            ${Float.round(@usd, 2)}
            <%= if @estimated? do %>
              <span class="text-xs font-sans font-medium opacity-60 ml-1">est.</span>
            <% end %>
          </p>
        </div>
        <div>
          <p class="text-xs opacity-60">Tokens</p>
          <p class="text-xl font-semibold font-mono mt-0.5">{format_tokens(@tokens)}</p>
        </div>
        <div class="text-xs opacity-50 self-end pb-1">
          {@records} ledger {if @records == 1, do: "record", else: "records"}
        </div>
      </div>
    </section>
    """
  end

  defp window_caption("session"), do: "All ledger rows in this database"
  defp window_caption("24h"), do: "Wall-clock last 24 hours"
  defp window_caption("7d"), do: "Wall-clock last 7 days"
  defp window_caption(_), do: "Window applies to cost and tokens only"

  attr :window, :string, required: true

  defp time_window_picker(assigns) do
    ~H"""
    <div class="flex items-center gap-1" role="group" aria-label="Spend time window">
      <%= for {value, label} <- [{"session", "Session"}, {"24h", "24h"}, {"7d", "7d"}] do %>
        <button
          type="button"
          phx-click="set_window"
          phx-value-window={value}
          aria-pressed={to_string(@window == value)}
          class={[
            "btn btn-xs",
            @window == value && "btn-primary",
            @window != value && "btn-ghost"
          ]}
        >
          {label}
        </button>
      <% end %>
    </div>
    """
  end

  attr :task_distribution, :map, required: true
  attr :orchestrator, :map, required: true

  defp queue_strip(assigns) do
    total = Enum.reduce(assigns.task_distribution, 0, fn {_k, v}, acc -> acc + v end)
    running = Map.get(assigns.orchestrator || %{}, :running, 0)

    assigns = assign(assigns, total_tasks: total, running: running)

    ~H"""
    <p class="text-xs opacity-70 flex flex-wrap gap-x-3 gap-y-1">
      <span>
        Tickets <span class="font-mono font-medium text-base-content">{@total_tasks}</span>
      </span>
      <span>
        Running
        <span class={[
          "font-mono font-medium",
          @running > 0 && "text-primary",
          @running == 0 && "text-base-content"
        ]}>
          {@running}
        </span>
      </span>
    </p>
    """
  end

  attr :agents, :list, required: true

  defp agent_roster(assigns) do
    agents = assigns.agents || []
    {active, idle} = Enum.split_with(agents, &(&1.busy? or &1.total_assigned > 0))
    # If nobody has work yet, show the full registered team so empty isn't blank.
    show = if active == [], do: agents, else: active
    idle_count = if active == [], do: 0, else: length(idle)

    assigns = assign(assigns, show: show, idle_count: idle_count)

    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-200/60 p-4">
      <h2 class="text-sm font-semibold mb-3">Who's working</h2>
      <%= if @show == [] do %>
        <p class="text-sm opacity-50">No agents registered. Add agents in Setup.</p>
      <% else %>
        <ul class="space-y-2">
          <%= for agent <- @show do %>
            <li class="flex items-center justify-between gap-3 rounded-md bg-base-100/80 px-3 py-2">
              <div class="flex items-center gap-2 min-w-0">
                <span class={[
                  "inline-flex items-center justify-center size-7 shrink-0 rounded-full text-xs font-semibold",
                  agent.busy? && "bg-primary/20 text-primary",
                  !agent.busy? && "bg-base-300 text-base-content/60"
                ]}>
                  {agent.avatar || String.first(agent.display_name) |> String.upcase()}
                </span>
                <div class="min-w-0">
                  <p class="text-sm font-medium truncate">{agent.display_name}</p>
                  <p class="text-xs opacity-60 truncate">
                    {agent.role || agent.model || "agent"}
                  </p>
                </div>
              </div>
              <div class="flex flex-col items-end gap-0.5 shrink-0">
                <div class="flex items-center gap-2 text-xs">
                  <%= if agent.busy? do %>
                    <span class="badge badge-primary badge-xs gap-1">
                      <span class="w-1.5 h-1.5 rounded-full bg-primary-content motion-safe:animate-pulse" />
                      busy
                    </span>
                  <% end %>
                  <span
                    class="font-mono opacity-70"
                    title={"#{agent.active_count} active · #{agent.completed_count} done · #{agent.failed_count} failed"}
                  >
                    {agent.active_count} active · {agent.completed_count} done
                    <%= if agent.failed_count > 0 do %>
                      <span class="text-error">· {agent.failed_count} failed</span>
                    <% end %>
                  </span>
                </div>
                <%= if agent.running_task_title do %>
                  <a
                    href={~p"/board?#{[task: agent.running_task_id]}"}
                    class="text-xs opacity-60 truncate max-w-[180px] hover:opacity-100 hover:text-primary"
                    title={agent.running_task_title}
                  >
                    {agent.running_task_title}
                  </a>
                <% end %>
              </div>
            </li>
          <% end %>
        </ul>
        <%= if @idle_count > 0 do %>
          <p class="text-xs opacity-50 mt-3">{@idle_count} idle</p>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :distribution, :map, required: true

  defp task_breakdown(assigns) do
    total = Enum.reduce(assigns.distribution, 0, fn {_k, v}, acc -> acc + v end)

    assigns =
      assign(assigns,
        total: max(total, 1),
        empty?: total == 0
      )

    ordered_cols = [
      {"todo", "Todo", "bg-base-300"},
      {"pending_approval", "Pending", "bg-warning/30"},
      {"in_progress", "Running", "bg-primary/30"},
      {"review", "Review", "bg-accent/30"},
      {"done", "Done", "bg-success/30"},
      {"failed", "Failed", "bg-error/30"}
    ]

    assigns = assign(assigns, :ordered_cols, ordered_cols)

    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-200/60 p-4">
      <h2 class="text-sm font-semibold mb-3">Task distribution</h2>
      <%= if @empty? do %>
        <p class="text-sm opacity-50">No tasks yet.</p>
      <% else %>
        <div class="space-y-2">
          <%= for {key, label, color_class} <- @ordered_cols do %>
            <% count = Map.get(@distribution, key, 0) %>
            <% pct = round(count * 100 / @total) %>
            <div class="flex items-center gap-2 text-sm">
              <span class="w-24 shrink-0 text-xs opacity-70">{label}</span>
              <div class="flex-1 h-2 rounded-full bg-base-300/50 overflow-hidden">
                <div
                  class={["h-full rounded-full transition-all", color_class]}
                  style={"width: #{max(pct, 0)}%"}
                />
              </div>
              <span class="w-8 text-right font-mono text-xs opacity-60">{count}</span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :runs, :list, required: true

  defp recent_runs(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-200/60 p-4">
      <h2 class="text-sm font-semibold mb-3">Recent runs</h2>
      <%= if @runs == [] do %>
        <p class="text-sm opacity-50">No completed runs yet.</p>
      <% else %>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr class="text-xs opacity-60">
                <th>Task</th>
                <th>Agent</th>
                <th>Status</th>
                <th class="text-right">Cost</th>
              </tr>
            </thead>
            <tbody>
              <%= for run <- @runs do %>
                <tr class="hover">
                  <td class="max-w-[220px] truncate text-sm">
                    <a
                      href={~p"/board?#{[task: run.id]}"}
                      class="hover:text-primary hover:underline underline-offset-2"
                    >
                      {run.title}
                    </a>
                  </td>
                  <td class="text-sm">{run.display_name}</td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      run.status == "done" && "badge-success",
                      run.status == "review" && "badge-warning",
                      run.status == "failed" && "badge-error"
                    ]}>
                      {run.status}
                    </span>
                  </td>
                  <td class="text-right font-mono text-xs">
                    <%= if run.cost_usd do %>
                      ${run.cost_usd}{if run.estimated, do: " est.", else: ""}
                    <% else %>
                      <span class="opacity-40">—</span>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Helpers --

  defp load_dashboard(socket) do
    snapshot = Dashboard.snapshot()
    cost = Dashboard.cost_for_window(socket.assigns[:time_window] || "session")

    assign(socket,
      snapshot: snapshot,
      window_cost: cost,
      time_window: socket.assigns[:time_window] || "session",
      error: nil,
      connected: true,
      now_mono: System.monotonic_time(:millisecond),
      page_title: "Dashboard",
      reload_timer: nil
    )
  rescue
    e in [DBConnection.ConnectionError, ErlangError, ArgumentError] ->
      assign(socket,
        snapshot: empty_snapshot(),
        window_cost: empty_window_cost(),
        time_window: socket.assigns[:time_window] || "session",
        error: Exception.message(e),
        connected: true,
        now_mono: System.monotonic_time(:millisecond),
        page_title: "Dashboard"
      )
  end

  defp empty_snapshot do
    %{
      tasks: [],
      agents: %{},
      orchestrator: %{},
      agent_roster: [],
      task_distribution: %{},
      human_wait: Board.human_wait_summary([]),
      session_cost: empty_window_cost(),
      session_totals: %{prompt_tokens: 0, completion_tokens: 0, record_count: 0},
      recent_runs: []
    }
  end

  defp empty_window_cost do
    %{
      total_cost_usd: 0.0,
      record_count: 0,
      prompt_tokens: 0,
      completion_tokens: 0,
      estimated: false
    }
  end

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"

  defp last_poll_label(o, now_mono) when is_map(o) and is_integer(now_mono) do
    case Map.get(o, :last_tick_mono_ms) do
      ms when is_integer(ms) ->
        age_s = max(div(now_mono - ms, 1000), 0)
        format_age(age_s)

      _ ->
        nil
    end
  end

  defp last_poll_label(_, _), do: nil

  defp format_age(s) when s < 5, do: "just now"
  defp format_age(s) when s < 60, do: "#{s}s ago"
  defp format_age(s) when s < 3600, do: "#{div(s, 60)}m ago"
  defp format_age(s), do: "#{div(s, 3600)}h ago"
end
