defmodule SvarmWeb.BoardLive.Column do
  @moduledoc """
  Kanban column and task-card markup for the team board.
  """
  use SvarmWeb, :html

  alias Svarm.{AgentRegistry, Board}

  import SvarmWeb.BoardLive.Helpers
  import SvarmWeb.BoardLive.Shared

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

  def column(assigns) do
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
end
