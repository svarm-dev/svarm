defmodule SvarmWeb.BoardLive.Chrome do
  @moduledoc """
  Board chrome: load error, empty/onboarding, demo banner, orchestrator bar.
  """
  use SvarmWeb, :html

  import SvarmWeb.BoardLive.Helpers

  attr :tasks_by_id, :map, required: true
  attr :checklist, :map, default: %{}

  def demo_bridge_banner(assigns) do
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

  attr :message, :string, required: true

  def board_load_error(assigns) do
    ~H"""
    <section
      class="rounded-lg border border-error/30 bg-error/5 px-6 py-8"
      aria-labelledby="board-error-title"
    >
      <h2 id="board-error-title" class="text-lg font-semibold tracking-tight text-error">
        Cannot load the board
      </h2>
      <p class="mt-2 max-w-2xl text-sm opacity-80">{@message}</p>
      <button type="button" phx-click="refresh" class="btn btn-sm btn-outline mt-4">
        Retry
      </button>
    </section>
    """
  end

  attr :checklist, :map, default: %{}
  attr :demo_routes, :boolean, default: false

  def board_empty(assigns) do
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

  def orchestrator_bar(assigns) do
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
end
