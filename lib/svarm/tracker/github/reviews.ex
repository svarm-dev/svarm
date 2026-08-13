defmodule Svarm.Tracker.GitHub.Reviews do
  @moduledoc """
  Poll GitHub pull-request reviews and classify the latest submitted state.

  Signal path for review-resume detection (issue #112): poll on orchestrator
  tick — not webhooks. Resume/re-dispatch is issue #113, not this module.

  Classification (latest submitted review per user; PENDING/DISMISSED ignored):
  - any latest `CHANGES_REQUESTED` → `:changes_requested`
  - else → `:none`

  Uses Req only. Requires `pull_requests:read` on the token/App.
  """

  require Logger

  alias Svarm.GitHub.AppAuth

  @base_url "https://api.github.com"
  @api_version "2026-03-10"
  @page_size 100
  @default_receive_timeout_ms 5_000
  @default_connect_timeout_ms 3_000

  @type decision :: :changes_requested | :none

  @type summary :: %{
          head_sha: String.t() | nil,
          decision: decision(),
          draft: boolean(),
          reviewer_logins: [String.t()],
          summary: String.t() | nil,
          review_count: non_neg_integer()
        }

  @doc """
  Summarize submitted reviews for `owner/repo` PR `pr_number`.

  `config` is a tracker config map (token via AppAuth or `:api_key`).
  Options:
  - `:req` — Req module override for tests
  """
  @spec summarize_pr_reviews(String.t(), String.t(), pos_integer(), map(), keyword()) ::
          {:ok, summary()} | {:error, term()}
  def summarize_pr_reviews(owner, repo, pr_number, config, opts \\ [])
      when is_binary(owner) and is_binary(repo) and is_integer(pr_number) do
    req = Keyword.get(opts, :req, Req)
    headers = headers(config)
    req_opts = req_opts(opts)

    with {:ok, pr} <- fetch_pr(req, owner, repo, pr_number, headers, req_opts),
         {:ok, head_sha, draft?} <- pr_head(pr),
         {:ok, reviews} <- fetch_all_reviews(req, owner, repo, pr_number, headers, req_opts) do
      {:ok, classify(reviews, head_sha, draft?)}
    end
  end

  @doc "Classify a list of review maps (GitHub API shape)."
  @spec classify([map()], String.t() | nil, boolean()) :: summary()
  def classify(reviews, head_sha, draft? \\ false) when is_list(reviews) do
    latest = latest_submitted_by_user(reviews)
    requested = Enum.filter(latest, &(&1.state == "CHANGES_REQUESTED"))
    logins = Enum.map(requested, & &1.login)
    decision = if logins == [], do: :none, else: :changes_requested

    %{
      head_sha: head_sha,
      decision: decision,
      draft: draft?,
      reviewer_logins: logins,
      summary: summary_text(decision, logins),
      review_count: length(reviews)
    }
  end

  defp latest_submitted_by_user(reviews) do
    reviews
    |> Enum.map(&normalize_review/1)
    |> Enum.reject(&(&1.state in ["PENDING", "DISMISSED"] or is_nil(&1.login)))
    |> Enum.group_by(& &1.login)
    |> Enum.map(fn {_login, user_reviews} ->
      Enum.max_by(user_reviews, & &1.submitted_at)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_review(review) when is_map(review) do
    review = stringify_top_keys(review)
    user = stringify_top_keys(review["user"] || %{})

    %{
      login: bin_field(user, "login"),
      state: review["state"] && String.upcase(to_string(review["state"])),
      submitted_at: bin_field(review, "submitted_at") || ""
    }
  end

  defp summary_text(:changes_requested, logins) do
    {shown, rest} = Enum.split(logins, 8)
    names = Enum.join(shown, ", ")
    more = if rest == [], do: "", else: " (+#{length(rest)} more)"
    "Changes requested by #{names}#{more}"
  end

  defp summary_text(:none, _logins), do: "no changes requested"

  defp pr_head(pr) when is_map(pr) do
    pr = stringify_top_keys(pr)
    head = stringify_top_keys(pr["head"] || %{})
    head_sha = bin_field(head, "sha")
    draft? = pr["draft"] == true

    if is_binary(head_sha) and head_sha != "" do
      {:ok, head_sha, draft?}
    else
      {:error, :missing_head_sha}
    end
  end

  defp req_opts(opts) do
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout_ms)
    connect_timeout = Keyword.get(opts, :connect_timeout, @default_connect_timeout_ms)

    [
      receive_timeout: receive_timeout,
      connect_options: [timeout: connect_timeout]
    ]
  end

  defp fetch_pr(req, owner, repo, pr_number, headers, req_opts) do
    url = "#{@base_url}/repos/#{owner}/#{repo}/pulls/#{pr_number}"
    http_map(req.get(url, [headers: headers] ++ req_opts), "PR")
  end

  defp fetch_all_reviews(req, owner, repo, pr_number, headers, req_opts) do
    ctx = %{
      req: req,
      owner: owner,
      repo: repo,
      pr_number: pr_number,
      headers: headers,
      req_opts: req_opts
    }

    fetch_reviews_page(ctx, 1, [])
  end

  defp fetch_reviews_page(ctx, page, acc) do
    url = "#{@base_url}/repos/#{ctx.owner}/#{ctx.repo}/pulls/#{ctx.pr_number}/reviews"
    params = %{per_page: @page_size, page: page}

    case ctx.req.get(url, [params: params, headers: ctx.headers] ++ ctx.req_opts) do
      {:ok, %{status: 200, body: body}} ->
        continue_or_done(ctx, page, acc, body)

      {:ok, %{status: 404}} ->
        {:ok, []}

      other ->
        map_http_error(other, "reviews")
    end
  end

  defp continue_or_done(ctx, page, acc, body) do
    reviews = reviews_from_body(body)
    acc = acc ++ reviews

    if full_page?(reviews) do
      fetch_reviews_page(ctx, page + 1, acc)
    else
      {:ok, acc}
    end
  end

  defp reviews_from_body(body) when is_list(body), do: body
  defp reviews_from_body(_), do: []

  defp stringify_top_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_top_keys(_), do: %{}

  defp bin_field(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp full_page?(reviews) do
    Enum.count_until(reviews, @page_size + 1) == @page_size
  end

  defp http_map({:ok, %{status: 200, body: body}}, _label) when is_map(body), do: {:ok, body}
  defp http_map({:ok, %{status: 404}}, _label), do: {:error, :not_found}
  defp http_map(other, label), do: map_http_error(other, label)

  defp map_http_error({:ok, %{status: 401}}, _label), do: {:error, :auth_failure}
  defp map_http_error({:ok, %{status: 403}}, _label), do: {:error, :forbidden}
  defp map_http_error({:ok, %{status: code}}, _label), do: {:error, {:http_error, code}}

  defp map_http_error({:error, reason}, label) do
    Logger.warning("github reviews: #{label} fetch failed: #{inspect(reason)}")
    {:error, :network_error}
  end

  defp headers(config) when is_map(config) do
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
end
