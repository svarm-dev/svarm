defmodule Svarm.Tracker.GitHub do
  @moduledoc """
  GitHub Issues tracker adapter. Implements `Svarm.Tracker` behaviour
  using the GitHub REST API via Req.

  Status mapping: Svärm statuses ↔ GitHub labels, configured via
  WORKFLOW.md `tracker.status_labels`. Terminal states close the issue
  with `state_reason: completed`.

  Uses `X-GitHub-Api-Version: 2026-03-10` header.
  """
  @behaviour Svarm.Tracker

  alias Svarm.GitHub.AppAuth
  alias Svarm.Tracker.GitHub.Eligibility
  alias Svarm.Tracker.GitHub.Normalize

  require Logger

  @base_url "https://api.github.com"
  @api_version "2026-03-10"

  # Default label↔status mapping. Operators can override in WORKFLOW.md.
  @default_status_labels %{
    "status: in-progress" => "in_progress",
    "status: done" => "done",
    "status: failed" => "failed",
    "status: review" => "review"
  }

  @default_reverse_labels %{
    "in_progress" => "status: in-progress",
    "done" => "status: done",
    "failed" => "status: failed",
    "review" => "status: review"
  }

  @impl true
  def capabilities, do: [:ci_poll, :review_poll, :connectivity_probe]

  @impl true
  def list_eligible(config) do
    owner = Map.fetch!(config, :owner)
    repo = Map.fetch!(config, :repo)

    url = "#{@base_url}/repos/#{owner}/#{repo}/issues"
    params = %{state: "open", per_page: 100}
    req = req_mod(config)

    map_list_http(
      req.get(url, params: params, headers: headers(config)),
      owner,
      repo,
      fn issues ->
        status_labels = Map.get(config, :status_labels, @default_status_labels)
        normalized_config = Map.put(config, :status_labels, status_labels)

        issues
        |> Enum.map(&Normalize.from_api_response(&1, normalized_config))
        |> Enum.filter(&Eligibility.eligible?(&1, config))
      end
    )
  end

  @impl true
  def get_issue(config, id) do
    owner = Map.fetch!(config, :owner)
    repo = Map.fetch!(config, :repo)

    # Try single-issue endpoint if id looks like a GitHub issue number
    case Integer.parse(id) do
      {number, ""} ->
        url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{number}"

        case Req.get(url, headers: headers(config)) do
          {:ok, %{status: 200, body: gh_issue}} ->
            status_labels = Map.get(config, :status_labels, @default_status_labels)

            {:ok,
             Normalize.from_api_response(gh_issue, Map.put(config, :status_labels, status_labels))}

          _ ->
            {:error, :not_found}
        end

      _ ->
        find_issue_by_id_fallback(config, id)
    end
  end

  defp find_issue_by_id_fallback(config, id) do
    case list_eligible(config) do
      {:ok, issues} ->
        case Enum.find(issues, &(&1.id == id)) do
          nil -> {:error, :not_found}
          issue -> {:ok, issue}
        end

      _ ->
        {:error, :not_found}
    end
  end

  @impl true
  def list_issues(config, filters \\ []) do
    {include_body, filters} = Keyword.pop(filters, :include_body, true)
    owner = Map.fetch!(config, :owner)
    repo = Map.fetch!(config, :repo)

    url = "#{@base_url}/repos/#{owner}/#{repo}/issues"
    params = build_list_params(filters)
    req = req_mod(config)

    map_list_http(
      req.get(url, params: params, headers: headers(config)),
      owner,
      repo,
      fn issues ->
        normalize_listed_issues(issues, config, include_body)
      end
    )
  end

  defp req_mod(config) when is_map(config) do
    Map.get(config, :req) || Application.get_env(:svarm, :github_req, Req)
  end

  defp map_list_http(resp, owner, repo, on_ok) when is_function(on_ok, 1) do
    case resp do
      {:ok, %{status: 200, body: issues}} ->
        {:ok, on_ok.(issues)}

      {:ok, %{status: 401}} ->
        {:error, error(:auth_failure, "bad GitHub token")}

      {:ok, %{status: 403} = resp} ->
        retry = parse_retry_after(resp.headers)
        {:error, error(:rate_limit, "rate limited", retry)}

      {:ok, %{status: 404}} ->
        {:error, error(:not_found, "repo #{owner}/#{repo} not found")}

      {:ok, %{status: code}} when code >= 500 ->
        {:error, error(:server_error, "GitHub API error #{code}")}

      {:error, %{reason: reason}} ->
        Logger.error("github tracker: #{inspect(reason)}")
        {:error, error(:network_error, "cannot reach GitHub API")}
    end
  end

  defp normalize_listed_issues(issues, config, include_body) do
    status_labels = Map.get(config, :status_labels, @default_status_labels)
    normalized_config = Map.put(config, :status_labels, status_labels)

    issues
    |> Enum.map(&Normalize.from_api_response(&1, normalized_config))
    |> Enum.filter(&Eligibility.board_visible?(&1, normalized_config))
    |> maybe_strip_list_bodies(include_body)
  end

  defp maybe_strip_list_bodies(issues, true), do: issues
  defp maybe_strip_list_bodies(issues, false), do: Enum.map(issues, &strip_list_body/1)

  # Board/dashboard card lists do not need issue body or raw API payload.
  defp strip_list_body(%Svarm.Issue{} = issue) do
    %{issue | body: nil, raw: nil}
  end

  @impl true
  def create_issue(config, attrs) do
    owner = Map.fetch!(config, :owner)
    repo = Map.fetch!(config, :repo)

    url = "#{@base_url}/repos/#{owner}/#{repo}/issues"

    body = %{
      title: Map.get(attrs, :title, "Untitled"),
      body: Map.get(attrs, :body, ""),
      labels: build_create_labels(attrs, config)
    }

    case Req.post(url, json: body, headers: headers(config)) do
      {:ok, %{status: 201, body: gh_issue}} ->
        status_labels = Map.get(config, :status_labels, @default_status_labels)

        {:ok,
         Normalize.from_api_response(gh_issue, Map.put(config, :status_labels, status_labels))}

      {:ok, %{status: 401}} ->
        {:error, :auth_failure}

      other ->
        {:error, {:create_failed, inspect(other)}}
    end
  end

  @impl true
  def update_status(config, id, status) do
    reverse_labels = Map.get(config, :reverse_labels, @default_reverse_labels)

    case find_issue(config, id) do
      nil ->
        Logger.warning("github: cannot update_status for unknown issue #{id}")
        :ok

      issue ->
        new_labels = labels_for_status(issue.labels, status, reverse_labels)
        patch_issue(config, issue.source_id, new_labels, status)
    end
  end

  # `"todo"` has no status label — strip in/out-progress/review/done/failed labels
  # so Normalize maps the issue back to `hd(active_states)` (todo). Without this,
  # `Map.get(reverse_labels, "todo")` is nil and the old no-op left `status: review`.
  defp labels_for_status(current_labels, "todo", reverse_labels) do
    strip_status_labels(current_labels, reverse_labels)
  end

  defp labels_for_status(current_labels, status, reverse_labels) do
    label = Map.get(reverse_labels, status)
    update_label_list(current_labels, label, reverse_labels)
  end

  defp strip_status_labels(current_labels, reverse_labels) do
    status_values = Map.values(reverse_labels)
    Enum.reject(current_labels, &(&1 in status_values))
  end

  @impl true
  def update_attempts(_config, _id, _attempts), do: :ok

  @impl true
  def claim(config, id) do
    case find_issue(config, id) do
      nil ->
        :ok

      issue ->
        owner = Map.fetch!(config, :owner)
        repo = Map.fetch!(config, :repo)

        url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue.source_id}"
        labels = ["claimed" | issue.labels] |> Enum.uniq()

        Req.patch(url, json: %{labels: labels}, headers: headers(config))
        :ok
    end
  end

  @impl true
  def delete_all(_config), do: :ok

  @impl true
  def post_run_summary(config, id, summary) do
    owner = Map.fetch!(config, :owner)
    repo = Map.fetch!(config, :repo)
    run_id = summary.run_id
    marker = "<!-- svarm-run:#{run_id} -->"

    source_id =
      (summary.task && Map.get(summary.task, :source_id)) ||
        extract_source_id_from_config(config, id)

    if is_nil(source_id) do
      Logger.warning("github: post_run_summary missing source_id for #{id}")
      :ok
    else
      post_comment_if_missing(owner, repo, source_id, run_id, marker, summary, config)
    end
  end

  # -- private --

  defp post_comment_if_missing(owner, repo, issue_number, run_id, marker, summary, config) do
    if comment_exists?(owner, repo, issue_number, marker, config) do
      Logger.debug("github: comment already exists for run #{run_id}")
      :ok
    else
      body = build_comment(summary) <> "\n\n" <> marker
      url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"

      case Req.post(url, json: %{body: body}, headers: headers(config)) do
        {:ok, %{status: 201}} ->
          Logger.info("github: posted run summary (run #{run_id})")

        {:ok, %{status: 403} = resp} ->
          Logger.warning("github: comment forbidden for run #{run_id}: #{format_forbidden(resp)}")

        other ->
          Logger.warning("github: post_run_summary failed for run #{run_id}: #{inspect(other)}")
      end

      :ok
    end
  end

  defp find_issue(config, id) do
    case get_issue(config, id) do
      {:ok, issue} -> issue
      _ -> nil
    end
  end

  defp patch_issue(config, source_id, labels, status) do
    owner = Map.fetch!(config, :owner)
    repo = Map.fetch!(config, :repo)

    url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{source_id}"

    body =
      %{labels: labels |> Enum.uniq()}
      |> maybe_close(status)

    case Req.patch(url, json: body, headers: headers(config)) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 403} = resp} ->
        Logger.warning("github: issue update forbidden: #{format_forbidden(resp)}")

      other ->
        Logger.warning("github: issue update failed: #{inspect(other)}")
    end

    :ok
  end

  defp maybe_close(body, status) when status in ["done", "failed"],
    do: Map.merge(body, %{state: "closed", state_reason: "completed"})

  defp maybe_close(body, _status), do: body

  # Unknown status (no reverse label): leave labels unchanged (legacy behavior).
  defp update_label_list(current_labels, nil, _reverse_labels), do: current_labels

  defp update_label_list(current_labels, new_label, reverse_labels) do
    status_values = Map.values(reverse_labels)
    cleaned = strip_status_labels(current_labels, reverse_labels)

    if new_label in status_values do
      [new_label | cleaned]
    else
      cleaned
    end
  end

  defp build_list_params([]), do: %{state: "all", per_page: 100}

  defp build_list_params(filters) do
    params = %{state: "all", per_page: 100}

    Enum.reduce(filters, params, fn
      {:status, "todo"}, acc -> Map.put(acc, :labels, "none")
      {:status, status}, acc -> Map.put(acc, :labels, "status: #{status}")
      {:assignee, assignee}, acc -> Map.put(acc, :assignee, assignee)
      _, acc -> acc
    end)
  end

  defp build_create_labels(attrs, config) do
    labels = Map.get(config, :required_labels, [])

    type_label =
      case Map.get(attrs, :type) do
        "research" -> "research"
        "docs" -> "docs"
        _ -> nil
      end

    Enum.reject([type_label | labels], &is_nil/1)
  end

  defp headers(config) when is_map(config) do
    base = [
      accept: "application/vnd.github+json",
      "x-github-api-version": @api_version
    ]

    case AppAuth.token_for_repo(config) do
      {:ok, token} ->
        Keyword.put(base, :authorization, "Bearer #{token}")

      {:error, reason} ->
        Logger.warning("github: auth token unavailable: #{inspect(reason)}")
        base
    end
  end

  defp parse_retry_after(headers) do
    # Req v0.5+ headers shape: %{binary => [binary, ...]}
    val =
      get_in(headers, ["retry-after", Access.at(0)]) ||
        get_in(headers, ["Retry-After", Access.at(0)]) ||
        Map.get(headers, "retry-after") ||
        Map.get(headers, "Retry-After")

    cond do
      is_binary(val) -> String.to_integer(val)
      is_list(val) and val != [] -> val |> hd() |> to_string() |> String.to_integer()
      true -> 60
    end
  end

  # Never log Authorization. Surface GitHub's message + rate headers so we can
  # tell secondary rate limits from missing scopes / SSO / fine-grained perms.
  defp format_forbidden(%{headers: headers, body: body}) do
    msg =
      case body do
        %{"message" => m} when is_binary(m) -> m
        b when is_binary(b) -> String.slice(b, 0, 200)
        _ -> "forbidden"
      end

    remaining = header_value(headers, "x-ratelimit-remaining")
    reset = header_value(headers, "x-ratelimit-reset")
    retry = header_value(headers, "retry-after")
    "message=#{inspect(msg)} remaining=#{remaining} reset=#{reset} retry_after=#{retry}"
  end

  defp header_value(headers, name) when is_map(headers) do
    lower = String.downcase(name)

    get_in(headers, [name, Access.at(0)]) ||
      get_in(headers, [lower, Access.at(0)]) ||
      Map.get(headers, name) ||
      Map.get(headers, lower) ||
      "-"
  end

  defp error(type, message, retry_after \\ nil) do
    %{type: type, message: message, retry_after: retry_after}
  end

  # -- post_run_summary helpers --

  defp comment_exists?(owner, repo, issue_number, marker, config) do
    url = "#{@base_url}/repos/#{owner}/#{repo}/issues/#{issue_number}/comments"
    params = %{per_page: 30, sort: "created", direction: "desc"}

    case Req.get(url, params: params, headers: headers(config)) do
      {:ok, %{status: 200, body: comments}} when is_list(comments) ->
        Enum.any?(comments, fn c -> String.contains?(c["body"] || "", marker) end)

      _ ->
        false
    end
  end

  def build_comment(summary) do
    cost = summary.cost
    success? = match?(:ok, summary.result)
    status = if success?, do: "finished", else: "failed"

    header = build_header(summary, status, cost, success?)
    meta_rows = build_meta_rows(summary)
    review = if success?, do: review_line(summary), else: nil
    footer = build_console_link(summary)

    lines = [header, "", meta_rows, ""]
    lines = if review, do: lines ++ [review, ""], else: lines
    lines = if footer, do: lines ++ [footer], else: lines
    Enum.join(lines, "\n")
  end

  defp build_header(summary, status, cost, success?) do
    emoji = if success?, do: "✅", else: "❌"
    task_title = (summary.task && summary.task.title) || "##{summary.task_id}"

    parts = [emoji, " **", summary.agent_name, "** ", status, " ", task_title]
    parts = maybe_append_cost(parts, cost, summary)
    parts = maybe_append_duration(parts, summary)
    IO.iodata_to_binary(parts)
  end

  defp review_line(summary) do
    pr = summary[:pr_url] || summary[:branch]

    base = "**Awaiting human review** — do not merge without a human."

    cond do
      is_binary(pr) and String.starts_with?(pr, "http") ->
        base <> " PR: #{pr}"

      is_binary(pr) and pr != "" ->
        base <> " Branch: `#{pr}`"

      true ->
        base
    end
  end

  defp maybe_append_cost(parts, cost, summary) do
    if cost && cost.record_count > 0 do
      parts ++ [" — $", format_cost(cost), " · ", format_tokens(summary)]
    else
      parts
    end
  end

  defp maybe_append_duration(parts, summary) do
    if summary.duration_ms do
      parts ++ [" · ", format_duration(summary.duration_ms)]
    else
      parts
    end
  end

  defp format_cost(cost) do
    amount = to_string(Float.round(cost.total_cost_usd, 2))

    if Map.get(cost, :estimated) == true do
      amount <> " est."
    else
      amount
    end
  end

  defp build_meta_rows(summary) do
    rows = []
    rows = if summary.harness, do: rows ++ ["| **Harness** | #{summary.harness} |"], else: rows
    rows = if summary.model, do: rows ++ ["| **Model** | #{summary.model} |"], else: rows
    rows = rows ++ ["| **Session** | `#{summary.run_id}` |"]
    rows = if summary.branch, do: rows ++ ["| **Branch** | `#{summary.branch}` |"], else: rows

    ["| | |", "|---|---|" | rows] |> Enum.join("\n")
  end

  # Board reads are unauthenticated. Only embed a console URL when the operator
  # explicitly opts in — SVARM_BASE_URL alone is not enough (see SECURITY.md).
  defp build_console_link(summary) do
    if comment_console_links_enabled?() do
      case Application.get_env(:svarm, :console_base_url) do
        url when is_binary(url) and url != "" ->
          "→ Full run log: #{url}/board?task=#{summary.task_id}&attach=1"

        _ ->
          nil
      end
    end
  end

  defp comment_console_links_enabled? do
    Application.get_env(:svarm, :comment_console_links, false) == true
  end

  defp format_duration(ms) when is_integer(ms) do
    total_sec = div(ms, 1000)
    mins = div(total_sec, 60)
    sec = rem(total_sec, 60)

    if mins > 0 do
      "#{mins}m #{sec}s"
    else
      "#{sec}s"
    end
  end

  defp format_tokens(%{total_tokens: tokens}) when is_number(tokens) and tokens >= 1000,
    do: "#{Float.round(tokens / 1000, 1)}k tokens"

  defp format_tokens(%{total_tokens: tokens}) when is_number(tokens),
    do: "#{trunc(tokens)} tokens"

  defp format_tokens(_), do: nil

  defp extract_source_id_from_config(_config, _id), do: nil
end
