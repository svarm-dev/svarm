defmodule Svarm.GitHub.AppAuth do
  @moduledoc """
  GitHub App authentication: App JWT → installation access token.

  Supports PAT passthrough when `tracker.auth` is `:token` (default).
  Tokens are cached in ETS until near expiry. Never log token values.
  """

  require Logger

  @base_url "https://api.github.com"
  @api_version "2026-03-10"
  @table :svarm_github_app_tokens
  # Refresh 60s before GitHub's ~1h expiry
  @skew_ms 60_000
  # JWT lifetime (GitHub max 10 minutes)
  @jwt_ttl_s 9 * 60

  @doc "Return a Bearer token for GitHub REST calls from tracker config."
  def token_for_repo(config) when is_map(config) do
    case Map.get(config, :auth, :token) do
      :app -> installation_token(config)
      _ -> pat_token(config)
    end
  end

  @doc "Mint (or return cached) installation access token for App auth config."
  def installation_token(config) when is_map(config) do
    with {:ok, app_id} <- fetch_app_id(config),
         {:ok, pem} <- load_private_key(config),
         {:ok, installation_id} <- resolve_installation_id(config, app_id, pem) do
      case cached_token(installation_id) do
        {:ok, token} ->
          {:ok, token}

        :miss ->
          mint_and_cache(app_id, pem, installation_id)
      end
    end
  end

  @doc false
  def jwt(app_id, pem) when is_binary(app_id) and is_binary(pem) do
    now = System.system_time(:second)
    header = %{"alg" => "RS256", "typ" => "JWT"}
    payload = %{"iat" => now - 60, "exp" => now + @jwt_ttl_s, "iss" => app_id}

    with {:ok, key} <- decode_pem(pem) do
      signing_input = encode_part(header) <> "." <> encode_part(payload)
      signature = :public_key.sign(signing_input, :sha256, key)
      {:ok, signing_input <> "." <> b64url(signature)}
    end
  end

  @doc "Clear the token cache (tests)."
  def clear_cache do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  # -- private --

  defp pat_token(config) do
    case config[:api_key] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_github_token}
    end
  end

  defp fetch_app_id(config) do
    case config[:app_id] do
      id when is_binary(id) and id != "" -> {:ok, id}
      id when is_integer(id) -> {:ok, Integer.to_string(id)}
      _ -> {:error, :missing_github_app_id}
    end
  end

  defp load_private_key(config) do
    cond do
      is_binary(config[:private_key]) and config[:private_key] != "" ->
        {:ok, config[:private_key]}

      is_binary(config[:private_key_path]) and config[:private_key_path] != "" ->
        path = Path.expand(config[:private_key_path])

        case File.read(path) do
          {:ok, pem} -> {:ok, pem}
          {:error, reason} -> {:error, {:private_key_read_failed, reason}}
        end

      true ->
        {:error, :missing_github_app_private_key}
    end
  end

  defp resolve_installation_id(config, app_id, pem) do
    case config[:installation_id] do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      id when is_integer(id) ->
        {:ok, Integer.to_string(id)}

      _ ->
        fetch_installation_id(config, app_id, pem)
    end
  end

  defp fetch_installation_id(config, app_id, pem) do
    owner = config[:owner]
    repo = config[:repo]

    with false <- blank?(owner) or blank?(repo),
         {:ok, jwt} <- jwt(app_id, pem) do
      url = "#{@base_url}/repos/#{owner}/#{repo}/installation"
      parse_installation_response(Req.get(url, headers: app_headers(jwt)))
    else
      true -> {:error, :github_tracker_missing_owner_or_repo}
      {:error, _} = err -> err
    end
  end

  defp parse_installation_response({:ok, %{status: 200, body: %{"id" => id}}}),
    do: {:ok, to_string(id)}

  defp parse_installation_response({:ok, %{status: 404}}),
    do: {:error, :github_app_not_installed}

  defp parse_installation_response({:ok, %{status: 401}}),
    do: {:error, :github_app_auth_failure}

  defp parse_installation_response({:ok, %{status: code, body: body}}) do
    Logger.warning("github app: installation lookup failed #{code}")
    {:error, {:installation_lookup_failed, code, body}}
  end

  defp parse_installation_response({:error, reason}),
    do: {:error, {:network_error, reason}}

  defp mint_and_cache(app_id, pem, installation_id) do
    with {:ok, jwt} <- jwt(app_id, pem) do
      url = "#{@base_url}/app/installations/#{installation_id}/access_tokens"

      case Req.post(url, headers: app_headers(jwt), json: %{}) do
        {:ok, %{status: 201, body: %{"token" => token} = body}} ->
          expires_at = parse_expires_at(body["expires_at"])
          put_cache(installation_id, token, expires_at)
          {:ok, token}

        {:ok, %{status: 401}} ->
          {:error, :github_app_auth_failure}

        {:ok, %{status: 404}} ->
          {:error, :github_app_not_installed}

        {:ok, %{status: code, body: body}} ->
          Logger.warning("github app: token mint failed #{code}")
          {:error, {:token_mint_failed, code, body}}

        {:error, reason} ->
          {:error, {:network_error, reason}}
      end
    end
  end

  defp parse_expires_at(nil), do: System.system_time(:millisecond) + 50 * 60_000

  defp parse_expires_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> System.system_time(:millisecond) + 50 * 60_000
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        @table
    end
  end

  defp cached_token(installation_id) do
    ensure_table()
    now = System.system_time(:millisecond)

    case :ets.lookup(@table, installation_id) do
      [{^installation_id, token, expires_at}] when expires_at - @skew_ms > now ->
        {:ok, token}

      _ ->
        :miss
    end
  end

  defp put_cache(installation_id, token, expires_at) do
    ensure_table()
    :ets.insert(@table, {installation_id, token, expires_at})
    :ok
  end

  defp app_headers(jwt) do
    [
      authorization: "Bearer #{jwt}",
      accept: "application/vnd.github+json",
      "x-github-api-version": @api_version
    ]
  end

  defp decode_pem(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        try do
          {:ok, :public_key.pem_entry_decode(entry)}
        rescue
          e in [ErlangError, ArgumentError] ->
            {:error, {:invalid_private_key, Exception.message(e)}}
        end

      [] ->
        {:error, :invalid_private_key}
    end
  end

  defp encode_part(map) do
    map |> Jason.encode!() |> b64url()
  end

  defp b64url(data) when is_binary(data) do
    data
    |> Base.encode64(padding: false)
    |> String.replace("+", "-")
    |> String.replace("/", "_")
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
