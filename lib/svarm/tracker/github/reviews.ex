defmodule Svarm.Tracker.GitHub.Reviews do
  @moduledoc """
  Poll GitHub pull-request reviews and classify the latest submitted state.

  Signal path for review-resume detection: poll on orchestrator tick — not
  webhooks. Spawn/re-dispatch lives in `Svarm.ReviewResume` / the orchestrator,
  not this module.

  Classification (latest submitted review per user; PENDING/DISMISSED ignored):
  - any latest `CHANGES_REQUESTED` → `:changes_requested`
  - else → `:none`

  Uses Req only. Requires `pull_requests:read` on the token/App.
  """

  alias Svarm.Tracker.GitHub.HTTP

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
    headers = HTTP.headers(config)
    req_opts = HTTP.req_opts(opts)

    with {:ok, pr} <- HTTP.fetch_pr(req, owner, repo, pr_number, headers, req_opts),
         {:ok, head_sha, draft?} <- pr_head(pr),
         {:ok, reviews} <- fetch_all_reviews(req, owner, repo, pr_number, headers, req_opts) do
      {:ok, classify(reviews, head_sha, draft?)}
    end
  end

  @doc "Classify a list of review maps (GitHub API shape)."
  @spec classify([map()], String.t() | nil, boolean()) :: summary()
  def classify(reviews, head_sha, draft? \\ false) when is_list(reviews) do
    latest = latest_decision_by_user(reviews)
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

  defp latest_decision_by_user(reviews) do
    reviews
    |> Enum.map(&normalize_review/1)
    |> Enum.filter(&decision_state?/1)
    |> Enum.group_by(& &1.login)
    |> Enum.map(fn {_login, user_reviews} ->
      Enum.max_by(user_reviews, & &1.submitted_at)
    end)
  end

  defp decision_state?(%{login: login, state: state})
       when is_binary(login) and state in ["APPROVED", "CHANGES_REQUESTED"],
       do: true

  defp decision_state?(_), do: false

  defp normalize_review(review) when is_map(review) do
    review = HTTP.stringify_top_keys(review)
    user = HTTP.stringify_top_keys(review["user"] || %{})

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
    pr = HTTP.stringify_top_keys(pr)
    head = HTTP.stringify_top_keys(pr["head"] || %{})
    head_sha = bin_field(head, "sha")
    draft? = pr["draft"] == true

    if is_binary(head_sha) and head_sha != "" do
      {:ok, head_sha, draft?}
    else
      {:error, :missing_head_sha}
    end
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
    url = "#{HTTP.base_url()}/repos/#{ctx.owner}/#{ctx.repo}/pulls/#{ctx.pr_number}/reviews"
    params = %{per_page: HTTP.page_size(), page: page}

    case ctx.req.get(url, [params: params, headers: ctx.headers] ++ ctx.req_opts) do
      {:ok, %{status: 200, body: body}} ->
        continue_or_done(ctx, page, acc, body)

      {:ok, %{status: 404}} ->
        {:ok, []}

      other ->
        HTTP.map_http_error(other, "reviews")
    end
  end

  defp continue_or_done(ctx, page, acc, body) do
    reviews = reviews_from_body(body)
    acc = acc ++ reviews

    if HTTP.full_page?(reviews) do
      fetch_reviews_page(ctx, page + 1, acc)
    else
      {:ok, acc}
    end
  end

  defp reviews_from_body(body) when is_list(body), do: body
  defp reviews_from_body(_), do: []

  defp bin_field(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end
end
