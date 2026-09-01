defmodule SvarmWeb.BoardLive.RunConsole do
  @moduledoc """
  Selected-task run console: log, evidence, steer, abort, and gate actions.
  """
  use SvarmWeb, :html

  alias Svarm.{Approval, Board}

  import SvarmWeb.BoardLive.Helpers
  import SvarmWeb.BoardLive.Shared

  attr :task_id, :string, default: nil
  attr :task, :map, default: nil
  attr :log, :string, default: ""
  attr :meta, :map, default: %{}
  attr :agents, :map, default: %{}
  attr :cost, :map, default: nil
  attr :running_started, :map, default: %{}
  attr :now_mono, :integer, default: 0
  attr :focused, :boolean, default: false
  attr :running?, :boolean, default: false

  def run_console(assigns) do
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

          <.abort_control task_id={@task.id} running?={@running?} />

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

  attr :task_id, :string, required: true
  attr :running?, :boolean, required: true

  defp abort_control(assigns) do
    ~H"""
    <div id={"abort-run-#{@task_id}"} class="flex flex-wrap items-center gap-2">
      <button
        type="button"
        phx-click="abort_run"
        phx-value-id={@task_id}
        phx-disable-with="Aborting…"
        class={[
          "btn btn-sm btn-outline",
          @running? && "btn-error"
        ]}
        disabled={not @running?}
        aria-label={
          if @running?,
            do: "Abort this run. Ticket returns to Todo.",
            else: "No live run to abort"
        }
        title={
          if @running?,
            do: "Stop this run. Ticket returns to Todo.",
            else: "No live run to abort."
        }
      >
        Abort
      </button>
      <p :if={@running?} class="text-xs opacity-60">
        Stops this run. Ticket returns to Todo.
      </p>
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
end
