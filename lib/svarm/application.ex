defmodule Svarm.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Run migrations BEFORE starting the supervision tree so the database
    # is ready when the Orchestrator's first tick queries the tasks table.
    migrate_database()

    # Run migrations BEFORE starting the supervision tree
    migrate_database()

    children =
      [
        SvarmWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:svarm, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Svarm.PubSub},
        # Svärm orchestration — Repo must start before KanbanBridge
        Svarm.Repo,
        {Svarm.KanbanBridge, []},
        {Task.Supervisor, name: Svarm.TaskSup},
        {Svarm.Workflow.Store, workflow_store_opts()}
      ] ++
        workflow_watcher_children() ++
        [
          {Svarm.Orchestrator, orchestrator_opts()},
          SvarmWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: Svarm.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        maybe_clear_stale_approval_overlay()
        maybe_seed_demo()
        {:ok, pid}

      other ->
        other
    end
  end

  # Drop leftover :approval_overlay when this process is not a demo profile.
  defp maybe_clear_stale_approval_overlay do
    unless Svarm.Demo.demo_profile_active?() do
      Svarm.Demo.clear_approval_overlay()
    end
  end

  # SVARM_SEED_DEMO=1 → queue mock tasks when the board is empty (Docker demo path).
  defp maybe_seed_demo do
    if Application.get_env(:svarm, :seed_demo_on_boot, false) do
      case Svarm.Demo.seed_if_empty() do
        {:ok, count} ->
          require Logger
          Logger.info("SVARM_SEED_DEMO: queued #{count} demo tasks on the board")

        :already_has_tasks ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("SVARM_SEED_DEMO failed: #{inspect(reason)}")
      end
    end
  end

  # Start Repo, run migrations, stop Repo — so the supervisor starts it cleanly.
  defp migrate_database do
    db_path = Application.get_env(:svarm, Svarm.Repo)[:database]
    if db_path, do: File.mkdir_p!(Path.dirname(db_path))

    {:ok, _pid} = Svarm.Repo.start_link(name: Svarm.Repo, pool_size: 1)
    Ecto.Migrator.run(Svarm.Repo, :up, all: true)
    GenServer.stop(Svarm.Repo)
  end

  defp orchestrator_opts do
    []
    |> maybe_put_orchestrator_opt(:poll_interval_ms, :orchestrator_poll_interval_ms)
    |> maybe_put_orchestrator_opt(:workspace_root, :orchestrator_workspace_root)
    |> maybe_put_orchestrator_opt(:max_concurrent, :orchestrator_max_concurrent)
  end

  defp maybe_put_orchestrator_opt(opts, key, env_key)
       when key in [:poll_interval_ms, :max_concurrent] do
    case Application.get_env(:svarm, env_key) do
      val when is_integer(val) -> Keyword.put(opts, key, val)
      _ -> opts
    end
  end

  defp maybe_put_orchestrator_opt(opts, :workspace_root, env_key) do
    case Application.get_env(:svarm, env_key) do
      val when is_binary(val) -> Keyword.put(opts, :workspace_root, Path.expand(val))
      _ -> opts
    end
  end

  defp workflow_store_opts do
    path = Application.get_env(:svarm, :workflow_path)
    if path, do: [path: path], else: []
  end

  defp workflow_watcher_children do
    path =
      Application.get_env(:svarm, :workflow_path) ||
        Path.join(File.cwd!(), "WORKFLOW.md")

    if File.regular?(path), do: [{Svarm.Workflow.Watcher, path: path}], else: []
  end

  @impl true
  def config_change(changed, _new, removed) do
    SvarmWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
