defmodule SvarmWeb.DashboardLive do
  @moduledoc """
  Operational dashboard for team leads: who's doing what, is the queue moving,
  what did it cost. Read-only; task detail lives at /board.
  """
  use SvarmWeb, :live_view

  alias Svarm.{Dashboard, Events}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if connected?(socket) do
        Events.subscribe()
        load_dashboard(socket)
      else
        assign(socket,
          snapshot: empty_snapshot(),
          time_window: "session",
          window_cost: %{total_cost_usd: 0.0, record_count: 0},
          error: nil,
          connected: false
        )
      end

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
    {:noreply, load_dashboard(socket)}
  end

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info({:tasks_snapshot, _tasks}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info({:orchestrator_status, _status}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info({:run_finished, _task_id, _exit_code}, socket) do
    {:noreply, load_dashboard(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-5xl mx-auto space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-semibold tracking-tight">Dashboard</h1>
            <p class="text-sm opacity-70">Your blended team at a glance</p>
          </div>
          <div class="flex gap-2 items-center">
            <button type="button" phx-click="refresh" class="btn btn-sm btn-ghost">
              Refresh
            </button>
            <a href={~p"/board"} class="btn btn-sm btn-outline">Board</a>
          </div>
        </div>

        <%= if @error do %>
          <.error_card error={@error} />
        <% else %>
          <%= if not @connected do %>
            <.loading_skeleton />
          <% else %>
            <.time_window_picker window={@time_window} />

            <.metrics_bar
              task_distribution={@snapshot.task_distribution}
              cost={@window_cost}
              totals={@snapshot.session_totals}
              orchestrator={@snapshot.orchestrator}
            />

            <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
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
    <div class="space-y-6 animate-pulse">
      <div class="flex gap-1">
        <div class="h-6 w-16 rounded bg-base-300" />
        <div class="h-6 w-12 rounded bg-base-300" />
        <div class="h-6 w-12 rounded bg-base-300" />
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <%= for _ <- 1..4 do %>
          <div class="rounded-lg border border-base-300 bg-base-200/60 px-4 py-3">
            <div class="h-3 w-12 rounded bg-base-300 mb-2" />
            <div class="h-6 w-8 rounded bg-base-300" />
          </div>
        <% end %>
      </div>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
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

  attr :window, :string, required: true

  defp time_window_picker(assigns) do
    ~H"""
    <div class="flex items-center gap-1" role="group" aria-label="Time window">
      <%= for {value, label} <- [{"session", "Session"}, {"24h", "24h"}, {"7d", "7d"}] do %>
        <button
          type="button"
          phx-click="set_window"
          phx-value-window={value}
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
  attr :cost, :map, required: true
  attr :totals, :map, required: true
  attr :orchestrator, :map, required: true

  defp metrics_bar(assigns) do
    total_tasks = assigns.task_distribution |> Map.values() |> Enum.sum()
    running = Map.get(assigns.orchestrator, :running, 0)
    cost = assigns.cost.total_cost_usd || 0.0
    tokens = (assigns.totals[:prompt_tokens] || 0) + (assigns.totals[:completion_tokens] || 0)

    assigns =
      assign(assigns,
        total_tasks: total_tasks,
        running: running,
        cost: cost,
        tokens: tokens
      )

    ~H"""
    <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
      <.metric_card label="Tickets" value={@total_tasks} />
      <.metric_card label="Running" value={@running} accent={@running > 0} />
      <.metric_card label="Cost" value={"$#{Float.round(@cost, 2)}"} mono />
      <.metric_card label="Tokens" value={format_tokens(@tokens)} />
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :accent, :boolean, default: false
  attr :mono, :boolean, default: false

  defp metric_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-200/60 px-4 py-3">
      <p class="text-xs opacity-60">{@label}</p>
      <p class={[
        "text-xl font-semibold mt-0.5",
        @accent && "text-primary",
        @mono && "font-mono"
      ]}>
        {@value}
      </p>
    </div>
    """
  end

  attr :agents, :list, required: true

  defp agent_roster(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-200/60 p-4">
      <h2 class="text-sm font-semibold mb-3">Agent roster</h2>
      <%= if @agents == [] do %>
        <p class="text-sm opacity-50">No agents registered. Add agents in agents.toml.</p>
      <% else %>
        <ul class="space-y-2">
          <%= for agent <- @agents do %>
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
                  <p class="text-[10px] opacity-50 truncate">
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
                  <span class="font-mono opacity-60"
                        title={"#{agent.active_count} active / #{agent.completed_count} done / #{agent.failed_count} failed"}>
                    {agent.active_count}a {agent.completed_count}d
                    <%= if agent.failed_count > 0 do %>
                      <span class="text-error">{agent.failed_count}f</span>
                    <% end %>
                  </span>
                </div>
                <%= if agent.running_task_title do %>
                  <p class="text-[10px] opacity-50 truncate max-w-[180px]"
                     title={agent.running_task_title}>
                    {agent.running_task_title}
                  </p>
                <% end %>
              </div>
            </li>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end

  attr :distribution, :map, required: true

  defp task_breakdown(assigns) do
    total = assigns.distribution |> Map.values() |> Enum.sum()

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
                  <td class="max-w-[200px] truncate text-sm">{run.title}</td>
                  <td class="text-sm">{run.display_name}</td>
                  <td>
                    <span class={[
                      "badge badge-xs",
                      run.status in ["done", "review"] && "badge-success",
                      run.status == "failed" && "badge-error"
                    ]}>
                      {run.status}
                    </span>
                  </td>
                  <td class="text-right font-mono text-xs">
                    <%= if run.cost_usd do %>
                      ${run.cost_usd}
                    <% else %>
                      <span class="opacity-40">-</span>
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
    try do
      snapshot = Dashboard.snapshot()
      cost = Dashboard.cost_for_window(socket.assigns[:time_window] || "session")

      assign(socket,
        snapshot: snapshot,
        window_cost: cost,
        time_window: socket.assigns[:time_window] || "session",
        error: nil,
        connected: true
      )
    rescue
      e ->
        assign(socket,
          snapshot: empty_snapshot(),
          window_cost: %{total_cost_usd: 0.0, record_count: 0},
          time_window: socket.assigns[:time_window] || "session",
          error: Exception.message(e),
          connected: true
        )
    end
  end

  defp empty_snapshot do
    %{
      tasks: [],
      agents: %{},
      orchestrator: %{},
      agent_roster: [],
      task_distribution: %{},
      session_cost: %{total_cost_usd: 0.0, record_count: 0},
      session_totals: %{prompt_tokens: 0, completion_tokens: 0, record_count: 0},
      recent_runs: []
    }
  end

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"
end
