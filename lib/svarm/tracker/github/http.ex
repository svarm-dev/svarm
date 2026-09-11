defmodule Svarm.Tracker.GitHub.HTTP do
  @moduledoc false
  # Shared GitHub REST helpers for Checks, Reviews, issue-list paging, and PR-merged lookups (Req only).

  require Logger

  alias Svarm.GitHub.AppAuth

  @base_url "https://api.github.com"
  @api_version "2026-03-10"
  @page_size 100
  # Issue lists follow `Link: rel=next`. Cap so a 10k-issue repo cannot stall a tick.
  @max_list_pages 10
  @default_receive_timeout_ms 5_000
  @default_connect_timeout_ms 3_000

  def base_url, do: @base_url
  def page_size, do: @page_size
  def max_list_pages, do: @max_list_pages

  @doc """
  Next GitHub issues-list URL from a `Link: rel=next` header, or `nil`.

  Only same-origin (`#{@base_url}`) issue collection paths are followed —
  `/repos/{owner}/{repo}/issues` or `/repositories/{id}/issues`. Other hosts
  or paths are ignored so a forged header cannot redirect the poll loop.
  """
  @spec next_issues_url(term(), String.t(), String.t()) :: String.t() | nil
  def next_issues_url(headers, owner, repo)
      when is_binary(owner) and is_binary(repo) and owner != "" and repo != "" do
    case next_link(headers) do
      url when is_binary(url) ->
        if allowed_list_next?(url, owner, repo), do: url

      _ ->
        nil
    end
  end

  def next_issues_url(_headers, _owner, _repo), do: nil

  @doc false
  def next_link(headers) do
    headers
    |> link_header_values()
    |> Enum.find_value(&parse_rel_next/1)
  end

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

  @doc """
  Whether GitHub reports this pull request as merged.

  `{:ok, true}` only when the PR JSON has `"merged" == true`.
  Closed-unmerged PRs return `{:ok, false}`. HTTP and network errors
  are tagged tuples — callers must not treat them as merges.
  """
  @spec pr_merged(module(), String.t(), String.t(), pos_integer(), keyword(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def pr_merged(req, owner, repo, pr_number, headers, req_opts) do
    case fetch_pr(req, owner, repo, pr_number, headers, req_opts) do
      {:ok, body} -> {:ok, merged_flag(body)}
      error -> error
    end
  end

  defp merged_flag(body) when is_map(body) do
    stringify_top_keys(body)["merged"] == true
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

  defp link_header_values(headers) when is_map(headers) do
    headers
    |> Enum.flat_map(fn
      {k, v} -> if link_header_name?(k), do: List.wrap(v), else: []
    end)
  end

  defp link_header_values(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {k, v} -> if link_header_name?(k), do: List.wrap(v), else: []
      _ -> []
    end)
  end

  defp link_header_values(_), do: []

  defp link_header_name?(name) when is_atom(name), do: link_header_name?(Atom.to_string(name))
  defp link_header_name?(name) when is_binary(name), do: String.downcase(name) == "link"
  defp link_header_name?(_), do: false

  defp parse_rel_next(header) when is_binary(header) do
    case Regex.run(~r/<([^>]+)>\s*;\s*rel="next"/i, header) do
      [_, url] -> url
      _ -> nil
    end
  end

  defp parse_rel_next(_), do: nil

  defp allowed_list_next?(url, owner, repo) do
    uri = URI.parse(url)
    base = URI.parse(@base_url)

    uri.scheme == base.scheme and uri.host == base.host and
      list_collection_path?(uri.path, owner, repo)
  end

  defp list_collection_path?(path, owner, repo) when is_binary(path) do
    path == "/repos/#{owner}/#{repo}/issues" or
      String.match?(path, ~r/^\/repositories\/\d+\/issues$/)
  end

  defp list_collection_path?(_, _, _), do: false
end
