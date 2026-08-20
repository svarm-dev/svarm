defmodule Svarm.Runner.Cli do
  @moduledoc """
  CLI runner adapter. Executes an agent as a subprocess via System.cmd/Port.
  Implements `Svarm.Runner` behaviour.

  Mid-run UI inject (`extension_ui_request`) and operator steer are not
  supported here — those paths live on `Svarm.Runner.PiRPC`.
  """
  @behaviour Svarm.Runner

  require Logger

  alias Svarm.{Events, ProfileRouter, Toolchain, Tracker, Workspace}

  @agents_file Path.join(:code.priv_dir(:svarm), "agents.toml")

  @impl true
  def run(task, agent_config, opts) do
    Logger.info(
      "cli: dispatching #{task.id} with command=#{agent_config[:command]} model=#{agent_config[:model]}"
    )

    workspace_root = Keyword.get(opts, :workspace_root, Workspace.default_root())
    isolation = Keyword.get(opts, :workspace_isolation, :path)
    git_repo = Keyword.get(opts, :workspace_git_repo)
    tracker = Keyword.get(opts, :tracker, Tracker.Local)
    tracker_config = Keyword.get(opts, :tracker_config, %{})
    assignee = task.assignee || ProfileRouter.assign("#{task.title} #{task.body}")

    workspace_key = Workspace.key_for_issue(task)

    {workspace_path, _created_now} =
      Workspace.ensure!(workspace_key, workspace_root,
        isolation: isolation,
        git_repo: git_repo
      )

    attempt = (task.attempts || 0) + 1

    case Svarm.Runner.prepare_prompt(task, agent_config, workspace_path, attempt) do
      {:ok, prompt, _injected} ->
        do_run_agent(
          task,
          agent_config,
          opts,
          tracker_config,
          workspace_path,
          prompt,
          assignee,
          tracker
        )

      {:error, reason} ->
        Svarm.Runner.fail_prepare(task, tracker, tracker_config, reason, "cli")
    end
  end

  defp do_run_agent(
         task,
         agent_config,
         opts,
         tracker_config,
         workspace_path,
         prompt,
         assignee,
         tracker
       ) do
    log_path = Path.join(workspace_path, "run.log")

    args = build_args(agent_config, prompt, assignee)
    started_mono = System.monotonic_time(:millisecond)

    meta =
      Svarm.AgentRegistry.run_started_meta(task, agent_config)
      |> Map.merge(%{
        workspace_path: workspace_path,
        started_mono_ms: started_mono
      })

    Events.broadcast_run_started(task.id, meta)

    command = agent_config[:command] || raise("agent_config missing :command for #{assignee}")

    env_map =
      (agent_config[:env] || %{})
      |> Svarm.Runner.with_github_token(tracker_config)

    {out, exit_code} =
      try do
        stream_cmd(command, args, workspace_path, task.id, env_map)
      rescue
        e in [ErlangError, File.Error] ->
          Logger.error("runner cli spawn failed: #{inspect(e)}")
          {inspect(e), -1}
      end

    Svarm.Runner.write_run_log(log_path, out)
    Events.broadcast_run_finished(task.id, exit_code)

    # Success → review (human PR gate). Agents never mark done/merge.
    status = if exit_code == 0, do: "review", else: "failed"
    tracker.update_status(tracker_config, task.id, status)

    record_usage(task, assignee, agent_config, opts)

    if exit_code == 0 do
      :ok
    else
      Logger.warning("agent #{assignee} exited #{exit_code} for task #{task.id}")
      {:error, {:agent_exit, exit_code, out}}
    end
  end

  @doc """
  Parse priv/agents.toml into a map of agent configs.

  Optional `skills` is a list of path strings (pack directories or `SKILL.md`
  files). Omitted, empty, or malformed values become `[]` so existing configs
  without skills keep loading.

  Optional `tools` is a list of host executable names expected on PATH
  (preflight contract). Optional `tools_mode` is `"fail"` (default) or
  `"warn"`. See `Svarm.Toolchain` and docs/agents.md.
  """
  def load_agents(path \\ @agents_file) do
    with {:ok, contents} <- File.read(path),
         {:ok, map} <- Toml.decode(contents) do
      map
      |> Map.get("agent", %{})
      |> Enum.into(%{}, fn {key, cfg} ->
        {key,
         %{
           command: Map.fetch!(cfg, "command"),
           args: expand_demo_args(Map.get(cfg, "args", [])),
           env: Map.get(cfg, "env", %{}),
           display_name: Map.get(cfg, "name", key),
           role: Map.get(cfg, "role"),
           avatar: Map.get(cfg, "avatar"),
           adapter: Map.get(cfg, "adapter", "cli"),
           provider: Map.get(cfg, "provider"),
           model: Map.get(cfg, "model"),
           skills: normalize_skills(Map.get(cfg, "skills")),
           tools: Toolchain.normalize_tools(Map.get(cfg, "tools")),
           tools_mode: Toolchain.normalize_mode(Map.get(cfg, "tools_mode"))
         }}
      end)
    else
      _ -> %{}
    end
  end

  @doc """
  Normalize a raw `skills` value from TOML or Settings to a list of trimmed
  non-empty path strings. Non-lists and non-string entries are dropped.
  """
  def normalize_skills(nil), do: []

  def normalize_skills(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
  end

  def normalize_skills(_), do: []

  @doc "Resolve an agent config by name, falling back to the 'default' agent."
  def resolve!(name, agents) do
    name = if is_binary(name) and name != "", do: name, else: "default"

    Map.get(agents, name) || Map.get(agents, "default") ||
      raise "agent_not_configured: #{name}"
  end

  # -- private --

  defp build_args(agent_config, prompt, assignee) do
    agent_args = agent_config[:args] || []

    if demo_assignee?(assignee) do
      agent_args
    else
      agent_args ++ [prompt]
    end
  end

  defp stream_cmd(command, args, cwd, task_id, env_map) do
    executable = System.find_executable(command)

    if is_nil(executable) do
      msg = "executable not found: #{command}"
      Events.broadcast_agent_line(task_id, msg <> "\n")
      {msg, -1}
    else
      do_stream_cmd(executable, args, cwd, task_id, env_map)
    end
  end

  defp do_stream_cmd(executable, args, cwd, task_id, env_map) do
    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, {:args, args}, {:cd, cwd}, {:line, 65_000}]
      |> Svarm.Runner.maybe_add_env(env_map)

    port = Port.open({:spawn_executable, executable}, port_opts)
    drain_port(port, task_id, "", 0)
  end

  defp drain_port(port, task_id, acc, line_count) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        Events.broadcast_agent_line(task_id, line)
        acc2 = acc <> line <> "\n"
        drain_port(port, task_id, acc2, line_count + 1)

      {^port, {:data, data}} when is_binary(data) ->
        Events.broadcast_agent_line(task_id, data)
        drain_port(port, task_id, acc <> data, line_count + 1)

      {^port, {:exit_status, status}} ->
        {acc, status}
    after
      3_600_000 ->
        Port.close(port)
        Events.broadcast_agent_line(task_id, "\n[agent_runner: port receive timeout]\n")
        {acc, -1}
    end
  end

  defp demo_assignee?(name) when is_binary(name), do: String.starts_with?(name, "demo")

  defp expand_demo_args(args) do
    script = Path.join(:code.priv_dir(:svarm), "demo_agent.sh")

    Enum.map(args, fn
      "DEMO_SCRIPT" -> script
      other -> other
    end)
  end

  defp record_usage(task, assignee, agent_config, opts) do
    run_id = opts[:run_id] || default_run_id()

    Svarm.Usage.append(
      run_id: run_id,
      task_id: task.id,
      tenant: task.tenant,
      source: "worker",
      provider: agent_config[:provider] || "cli",
      model_id: agent_config[:model] || assignee,
      prompt_tokens: nil,
      completion_tokens: nil,
      estimated: true
    )
  end

  defp default_run_id, do: "run_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
