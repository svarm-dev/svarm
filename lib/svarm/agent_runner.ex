defmodule Svarm.AgentRunner do
  @moduledoc """
  Agent-agnostic runner facade. Delegates to the configured Runner adapter
  (CLI by default, pi RPC when configured via adapter field).

  Loads agent configs from priv/agents.toml and dispatches to the appropriate
  Runner adapter based on the agent's `adapter` field.
  """

  alias Svarm.Runner.{Cli, PiRPC}

  @doc "Parse priv/agents.toml into agent config maps, then merge Settings overrides."
  def load_agents(path \\ nil) do
    path =
      path || System.get_env("SVARM_AGENTS_PATH") ||
        Path.join(:code.priv_dir(:svarm), "agents.toml")

    path
    |> Cli.load_agents()
    |> Svarm.Settings.Resolve.merge_agents()
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

  @doc """
  Kill the OS agent process tree registered for a worker Task pid.

  Orchestrator stall, tracker-terminal stop, and board abort call this
  before `Process.exit/2`. Shell-out stays in `Svarm.Runner` (`kill_tree/1` —
  process-group / PGID when `pgrep` is absent). No-op if the worker never
  opened an agent Port.
  """
  @spec kill_os_tree(pid()) :: :ok
  def kill_os_tree(worker_pid) when is_pid(worker_pid) do
    Svarm.Runner.kill_for_worker(worker_pid)
  end
end
