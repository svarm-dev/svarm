defmodule Svarm.AgentRunner do
  @moduledoc """
  Agent-agnostic runner facade. Delegates to the configured Runner adapter
  (CLI by default, pi RPC when configured via adapter field).

  Loads agent configs from priv/agents.toml and dispatches to the appropriate
  Runner adapter based on the agent's `adapter` field.
  """

  alias Svarm.Runner.{Cli, PiRPC}

  @doc "Parse priv/agents.toml into agent config maps."
  def load_agents(path \\ nil) do
    path =
      path || System.get_env("SVARM_AGENTS_PATH") ||
        Path.join(:code.priv_dir(:svarm), "agents.toml")

    Cli.load_agents(path)
  end

  @doc "Resolve an agent config by name."
  defdelegate resolve!(name, agents), to: Cli

  @doc "Run a task via the configured runner adapter. Returns :ok | {:error, reason}."
  def run(task, opts \\ []) do
    agents = Keyword.get(opts, :agents) || load_agents()
    assignee = task.assignee || "default"
    agent_config = Cli.resolve!(assignee, agents)

    adapter = resolve_adapter(agent_config[:adapter])
    adapter.run(task, agent_config, opts)
  end

  @doc "Resolve the runner adapter from an agent config's adapter field."
  def resolve_adapter("pi_rpc"), do: PiRPC
  def resolve_adapter(_), do: Cli
end
