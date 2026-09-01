defmodule SvarmWeb.BoardLive.Shared do
  @moduledoc """
  Small board chips shared by columns and the run console (agent badge, CI).
  """
  use SvarmWeb, :html

  import SvarmWeb.BoardLive.Helpers

  attr :state, :atom, required: true

  def ci_evidence_chip(assigns) do
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

  attr :identity, :map, required: true
  attr :compact, :boolean, default: false
  attr :workload, :integer, default: nil

  def agent_badge(assigns) do
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
end
