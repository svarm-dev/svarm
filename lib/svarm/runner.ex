defmodule Svarm.Runner do
  @moduledoc """
  Behaviour for agent runners. Each adapter implements how to execute
  an agent for a given task — CLI subprocess, pi RPC session, etc.

  Shared Port helpers live here so CLI and PiRPC do not duplicate spawn or
  OS kill-tree logic. OTP's `erl_child_setup` already starts each Port in its
  own session / process group (equivalent to `setsid`). `kill_tree/1` signals
  that PGID when `pgrep` is missing (slim images). It never signals the BEAM
  process group.
  """
  require Logger

  alias Svarm.{Events, Issue, Skills}
  alias Svarm.Workflow.Render

  @ports_registry Svarm.Runner.Ports

  # When Port `env` is set it replaces the whole environment. Re-include only
  # these keys from the host process — not every secret Svärm may hold.
  @inherited_env ~w(
    PATH HOME LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES TERM
    USER LOGNAME TMPDIR TMP TEMP SHELL
  )

  @doc """
  Run an agent for the given task. The adapter handles workspace creation,
  prompt rendering, execution, streaming, and result reporting.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback run(
              task :: Issue.t(),
              agent_config :: map(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @doc """
  Helper for Port env options. Shared by CLI and PiRPC runners.

  Always sets Port `env` to an allowlist base (PATH, HOME, locale, temp, shell)
  plus any explicit agent overrides. Empty override map still uses the allowlist
  only — never full host inheritance (API keys must be listed in agents.toml).
  """
  def maybe_add_env(opts, env_map) when is_map(env_map) do
    base = allowlisted_host_env()

    env =
      Enum.reduce(env_map, base, fn {k, v}, acc ->
        Map.put(acc, String.to_charlist(to_string(k)), String.to_charlist(resolve_env_value(v)))
      end)
      |> Map.to_list()

    opts ++ [{:env, env}]
  end

  @doc """
  Open an agent Port and register its OS pid for the calling worker.

  OTP already places the Port in its own process group, so `kill_tree/1` can
  reap descendants via PGID when `pgrep` is absent. Do **not** wrap with
  `setsid`: the Port child is already a session leader, and a second `setsid`
  forks, the Port sees a fake exit, and the agent is orphaned (PPID 1).

  `kill_for_worker/1` (stall / tracker-terminal) looks up this pid. A monitor
  reaper also runs `kill_tree/1` if the worker is exited externally
  (`try/after` does not run on that path).
  """
  @spec open_agent_port(String.t(), keyword()) :: port()
  def open_agent_port(executable, port_opts)
      when is_binary(executable) and is_list(port_opts) do
    port = Port.open({:spawn_executable, executable}, port_opts)

    case port_os_pid(port) do
      os_pid when is_integer(os_pid) -> watch_worker_os_pid(os_pid)
      _ -> :ok
    end

    port
  end

  @doc """
  Close `port` if still open and `kill_tree/1` its OS pid.

  Used by PiRPC/CLI timeout abort. Safe if the Port is already closed.
  """
  @spec ensure_dead(port()) :: :ok
  def ensure_dead(port) do
    os_pid = port_os_pid(port)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    if is_integer(os_pid), do: kill_tree(os_pid)
    :ok
  end

  @doc """
  Kill the OS agent tree registered for a worker Task pid.

  No-op when the worker has not opened an agent Port. Orchestrator calls this
  via `Svarm.AgentRunner.kill_os_tree/1` before `Process.exit/2`.
  """
  @spec kill_for_worker(pid()) :: :ok
  def kill_for_worker(worker_pid) when is_pid(worker_pid) do
    case Registry.lookup(@ports_registry, worker_pid) do
      [{_owner, os_pid}] when is_integer(os_pid) -> kill_tree(os_pid)
      _ -> :ok
    end
  end

  @doc """
  Kill an agent OS process and its descendants.

  Order:
  1. If the agent's PGID is not the BEAM's, `kill -KILL -- -<pgid>` (the
     `pgrep`-absent fallback; OTP Port children are already a process group,
     equivalent to `setsid`).
  2. If `pgrep` is on PATH, walk `-P` children (covers a shared PGID).
  3. `kill -KILL` the pid itself.

  Never signals the BEAM process group. Cleanup failures are ignored so a
  successful run cannot crash in `after`.
  """
  @spec kill_tree(pos_integer()) :: :ok
  def kill_tree(os_pid) when is_integer(os_pid) and os_pid > 0 do
    kill_process_group_if_safe(os_pid)
    kill_pgrep_children(os_pid)
    signal_kill(Integer.to_string(os_pid))
    :ok
  end

  defp allowlisted_host_env do
    Enum.reduce(@inherited_env, %{}, fn key, acc ->
      case System.get_env(key) do
        nil -> acc
        val -> Map.put(acc, String.to_charlist(key), String.to_charlist(val))
      end
    end)
  end

  @doc """
  When tracker uses GitHub App auth, inject a fresh installation token as
  `GITHUB_TOKEN` / `GH_TOKEN` so agent git/`gh` ops run as the bot.
  """
  def with_github_token(env_map, tracker_config) when is_map(env_map) do
    case tracker_config do
      %{auth: :app} = config ->
        case Svarm.GitHub.AppAuth.token_for_repo(config) do
          {:ok, token} ->
            env_map
            |> Map.put("GITHUB_TOKEN", token)
            |> Map.put("GH_TOKEN", token)

          {:error, _reason} ->
            env_map
        end

      _ ->
        env_map
    end
  end

  def with_github_token(env_map, _), do: env_map

  @doc """
  Write agent output to the workspace `run.log`, redacting secrets first.

  Same scrubbing as PubSub/`RunLog` (`Svarm.Redact.text/1`) so env dumps and
  token shapes never persist unredacted under the workspace root.
  """
  def write_run_log(path, content) when is_binary(path) and is_binary(content) do
    File.write!(path, Svarm.Redact.text(content))
  end

  @doc """
  Inject configured skill packs into the workspace, render the task prompt, and
  append the skills section. Shared by CLI and PiRPC adapters.
  """
  @spec prepare_prompt(Issue.t(), map(), String.t(), non_neg_integer()) ::
          {:ok, String.t(), [Skills.injected()]} | {:error, term()}
  def prepare_prompt(task, agent_config, workspace_path, attempt)
      when is_map(agent_config) and is_binary(workspace_path) do
    with {:ok, injected} <- Skills.inject(agent_config[:skills], workspace_path),
         {:ok, prompt} <- Render.render_prompt(task, attempt) do
      {:ok, Skills.append_prompt_section(prompt, injected), injected}
    end
  end

  @doc """
  Fail a run when skill inject or prompt render fails. Marks the task `failed`
  and, for skills errors, broadcasts a clear board line.
  """
  @spec fail_prepare(Issue.t(), module(), map(), term(), String.t()) :: {:error, term()}
  def fail_prepare(task, tracker, tracker_config, reason, adapter_label)
      when is_binary(adapter_label) do
    if Skills.error?(reason) do
      msg = Skills.format_error(reason)
      Logger.error("#{adapter_label} skills inject failed for task #{task.id}: #{msg}")
      Events.broadcast_agent_line(task.id, "\n[skills: #{msg}]\n")
      tracker.update_status(tracker_config, task.id, "failed")
      {:error, reason}
    else
      Logger.error("prompt render failed for task #{task.id}: #{inspect(reason)}")
      tracker.update_status(tracker_config, task.id, "failed")
      {:error, {:prompt_render_error, reason}}
    end
  end

  defp resolve_env_value("$" <> var), do: System.get_env(var) || ""
  defp resolve_env_value(value), do: to_string(value)

  defp port_os_pid(port) do
    info = Port.info(port)
    info && Keyword.get(info, :os_pid)
  end

  defp watch_worker_os_pid(os_pid) when is_integer(os_pid) do
    worker = self()
    _ = Registry.register(@ports_registry, worker, os_pid)

    spawn(fn ->
      Process.monitor(worker)

      receive do
        {:DOWN, _ref, :process, ^worker, _reason} -> kill_tree(os_pid)
      end
    end)

    :ok
  end

  # Process-group kill is the pgrep-absent fallback. Skip when the agent
  # shares the BEAM's PGID so we never signal BEAM.
  defp kill_process_group_if_safe(os_pid) do
    beam_pgid = process_group_id(beam_os_pid())
    agent_pgid = process_group_id(os_pid)

    if is_integer(agent_pgid) and agent_pgid > 1 and agent_pgid != beam_pgid do
      signal_kill("-#{agent_pgid}")
    end

    :ok
  end

  defp kill_pgrep_children(os_pid) do
    case System.find_executable("pgrep") do
      nil ->
        :ok

      pgrep ->
        case System.cmd(pgrep, ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true) do
          {out, 0} -> Enum.each(String.split(out), &kill_parsed_child/1)
          _ -> :ok
        end
    end
  rescue
    e in [ErlangError] ->
      Logger.debug("kill_tree: pgrep #{os_pid} failed: #{inspect(e)}")
      :ok
  end

  defp kill_parsed_child(child) do
    case Integer.parse(child) do
      {cid, ""} when cid > 0 -> kill_tree(cid)
      _ -> :ok
    end
  end

  defp signal_kill(target) when is_binary(target) do
    case System.find_executable("kill") do
      nil ->
        :ok

      kill ->
        # `--` so a negative PGID is not parsed as another signal.
        _ = System.cmd(kill, ["-KILL", "--", target], stderr_to_stdout: true)
        :ok
    end
  rescue
    e in [ErlangError] ->
      Logger.debug("kill_tree: kill #{target} failed: #{inspect(e)}")
      :ok
  end

  defp beam_os_pid do
    :os.getpid() |> List.to_integer()
  end

  defp process_group_id(pid) when is_integer(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> parse_stat_pgrp(stat)
      _ -> nil
    end
  end

  # /proc/pid/stat: pid (comm) state ppid pgrp ...
  defp parse_stat_pgrp(stat) when is_binary(stat) do
    case :binary.match(stat, <<") ">>) do
      {idx, 2} ->
        rest = binary_part(stat, idx + 2, byte_size(stat) - idx - 2)
        parse_stat_pgrp_fields(String.split(rest, " ", parts: 4))

      :nomatch ->
        nil
    end
  end

  defp parse_stat_pgrp_fields([_state, _ppid, pgrp | _]) do
    case Integer.parse(pgrp) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_stat_pgrp_fields(_), do: nil
end
