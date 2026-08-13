defmodule Svarm.Tracker.GitHub.HTTP do
  @moduledoc false
  # Shared GitHub REST helpers for Checks and Reviews pollers (Req only).

  require Logger

  alias Svarm.GitHub.AppAuth

  @base_url "https://api.github.com"
  @api_version "2026-03-10"
  @page_size 100
  @default_receive_timeout_ms 5_000
  @default_connect_timeout_ms 3_000

  def base_url, do: @base_url
  def page_size, do: @page_size

  def req_opts(opts) do
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout_ms)
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout_ms)

    [
      receive_timeout: receive_timeout,
      connect_options: [timeout: connect_timeout]
    ]
  end

  def headers(config) when is_map(config) do
    base = [
      accept: "application/vnd.github+json",
      "x-github-api-version": @api_version
    ]

    case AppAuth.token_for_repo(config) do
      {:ok, token} ->
        Keyword.put(base, :authorization, "Bearer #{token}")

      {:error, _} ->
        case Map.get(config, :api_key) do
          token when is_binary(token) and token != "" ->
            Keyword.put(base, :authorization, "Bearer #{token}")

          _ ->
            base
        end
    end
  end

  def fetch_pr(req, owner, repo, pr_number, headers, req_opts) do
    url = "#{@base_url}/repos/#{owner}/#{repo}/pulls/#{pr_number}"
    http_map(req.get(url, [headers: headers] ++ req_opts), "PR")
  end

  def http_map({:ok, %{status: 200, body: body}}, _label) when is_map(body), do: {:ok, body}
  def http_map({:ok, %{status: 404}}, _label), do: {:error, :not_found}
  def http_map(other, label), do: map_http_error(other, label)

  def map_http_error({:ok, %{status: 401}}, _label), do: {:error, :auth_failure}
  def map_http_error({:ok, %{status: 403}}, _label), do: {:error, :forbidden}
  def map_http_error({:ok, %{status: code}}, _label), do: {:error, {:http_error, code}}

  def map_http_error({:error, reason}, label) do
    Logger.warning("github #{label}: fetch failed: #{inspect(reason)}")
    {:error, :network_error}
  end

  def full_page?(items), do: Enum.count_until(items, @page_size + 1) == @page_size

  def stringify_top_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  def stringify_top_keys(_), do: %{}
end
