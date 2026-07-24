defmodule Svarm.Runner do
  @moduledoc """
  Behaviour for agent runners. Each adapter implements how to execute
  an agent for a given task — CLI subprocess, pi RPC session, etc.
  """
  alias Svarm.Issue

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

  Empty override map → omit `env` (Port inherits the full process environment).

  Non-empty override map → merge overrides onto a **small allowlist** of host
  vars (PATH, HOME, locale, temp, shell). Does not forward API keys or other
  secrets unless the agent config lists them explicitly.
  """
  def maybe_add_env(opts, env_map) when map_size(env_map) == 0, do: opts

  def maybe_add_env(opts, env_map) do
    base =
      Enum.reduce(@inherited_env, %{}, fn key, acc ->
        case System.get_env(key) do
          nil -> acc
          val -> Map.put(acc, String.to_charlist(key), String.to_charlist(val))
        end
      end)

    env =
      Enum.reduce(env_map, base, fn {k, v}, acc ->
        Map.put(acc, String.to_charlist(to_string(k)), String.to_charlist(resolve_env_value(v)))
      end)
      |> Map.to_list()

    opts ++ [{:env, env}]
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

  defp resolve_env_value("$" <> var), do: System.get_env(var) || ""
  defp resolve_env_value(value), do: to_string(value)
end
