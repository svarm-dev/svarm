defmodule Svarm.ProfileRouter do
  @moduledoc """
  Keyword routing: task text → agent name from agents.toml.
  Routes tasks by keyword match or falls back to the default agent.
  """
  @default_assignee "default"

  @default_routes [
    %{
      keywords: ~w(infra server proxmox homelab mqtt zfs docker network vlan dns kubernetes),
      assignee: "default"
    },
    %{
      keywords: ~w(code api function module elixir phoenix ecto test bug refactor rest graphql),
      assignee: "default"
    },
    %{
      keywords:
        ~w(research paper benchmark compare evaluate investigate review survey docs documentation),
      assignee: "default"
    }
  ]

  def default, do: @default_assignee
  def routes, do: @default_routes

  def assign(text, routes \\ @default_routes) do
    lower = String.downcase(text)

    case Enum.find(routes, &Enum.any?(&1.keywords, fn kw -> String.contains?(lower, kw) end)) do
      nil -> @default_assignee
      route -> route.assignee
    end
  end
end
