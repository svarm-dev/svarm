defmodule Svarm.Runner do
  @moduledoc """
  Behaviour for agent runners. Each adapter implements how to execute
  an agent for a given task — CLI subprocess, pi RPC session, etc.
  """
  alias Svarm.Issue

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
  """
  def maybe_add_env(opts, env_map) when map_size(env_map) == 0, do: opts

  def maybe_add_env(opts, env_map) do
    env =
      Enum.map(env_map, fn {k, v} ->
        resolved = resolve_env_value(v)
        {String.to_charlist(k), String.to_charlist(resolved)}
      end)

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
  defp resolve_env_value(value), do: value
end
