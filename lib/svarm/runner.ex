defmodule Svarm.Runner do
  @moduledoc """
  Behaviour for agent runners. Each adapter implements how to execute
  an agent for a given task — CLI subprocess, pi RPC session, etc.
  """
  require Logger

  alias Svarm.{Events, Issue, Skills}
  alias Svarm.Workflow.Render

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
end
