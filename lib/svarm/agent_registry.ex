defmodule Svarm.AgentRegistry do
  @moduledoc """
  Normalizes agent identity from `agents.toml` for UI and run events.
  """
  @default_avatar "🤖"

  @doc "Public identity map for an assignee key."
  def identity(assignee, agents) when is_map(agents) do
    assignee = normalize_assignee(assignee)
    cfg = Map.get(agents, assignee) || Map.get(agents, "default") || %{}

    %{
      assignee: assignee,
      display_name: cfg[:display_name] || assignee,
      role: blank_to_nil(cfg[:role]),
      avatar: cfg[:avatar] || avatar_for(assignee),
      adapter: cfg[:adapter],
      model: cfg[:model]
    }
  end

  @doc "Metadata broadcast when a run starts."
  def run_started_meta(task, agent_config) when is_map(task) and is_map(agent_config) do
    # Map.get/2 works on structs; Access (task[:key]) does not without Access behaviour.
    assignee = normalize_assignee(Map.get(task, :assignee))
    attempts = Map.get(task, :attempts) || 0

    %{
      assignee: assignee,
      display_name: agent_config[:display_name] || assignee,
      role: blank_to_nil(agent_config[:role]),
      avatar: agent_config[:avatar] || avatar_for(assignee),
      adapter: agent_config[:adapter],
      model: agent_config[:model],
      attempt: attempts + 1
    }
  end

  @doc "Normalize an assignee key (nil/blank → \"default\")."
  def normalize_assignee(nil), do: "default"
  def normalize_assignee(""), do: "default"
  def normalize_assignee(name) when is_binary(name), do: name
  def normalize_assignee(_), do: "default"

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: String.trim(s)
  defp blank_to_nil(_), do: nil

  defp avatar_for("default"), do: "🤖"
  defp avatar_for("demo_research"), do: "🔍"
  defp avatar_for("demo_code"), do: "⚡"
  defp avatar_for("demo_docs"), do: "📝"
  defp avatar_for("demo"), do: "🤖"
  defp avatar_for(_), do: @default_avatar
end
