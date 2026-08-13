defmodule Svarm.Tracker.GitHub.Checks do
  @moduledoc """
  Poll GitHub Checks for a pull request head and classify CI outcome.

  Signal path for CI resume (issue #44): poll on orchestrator tick — not webhooks.

  Classification:
  - draft + `skip_draft` → `:pending`
  - any check-run not `completed` → `:in_progress`
  - all completed + any failure / timed_out / action_required / cancelled → `:failed`
  - else → `:passed` (including empty check list / all success|neutral|skipped)

  Uses Req only. Requires `checks:read` and `pull_requests:read` on the token/App.
  """

  alias Svarm.Tracker.GitHub.HTTP

  @fail_conclusions ~w(failure timed_out action_required cancelled)

  @type conclusion :: :pending | :in_progress | :failed | :passed | :error

  @type summary :: %{
          head_sha: String.t() | nil,
          conclusion: conclusion(),
          draft: boolean(),
          failed_names: [String.t()],
          summary: String.t() | nil,
          check_count: non_neg_integer()
        }

  @doc """
  Summarize Checks for `owner/repo` PR `pr_number`.

  `config` is a tracker config map (token via AppAuth or `:api_key`).
  Options:
  - `:skip_draft` (default true) — treat draft PRs as `:pending`
  - `:req` — Req module override for tests
  """
  @spec summarize_pr_checks(String.t(), String.t(), pos_integer(), map(), keyword()) ::
          {:ok, summary()} | {:error, term()}
  def summarize_pr_checks(owner, repo, pr_number, config, opts \\ [])
      when is_binary(owner) and is_binary(repo) and is_integer(pr_number) do
    req = Keyword.get(opts, :req, Req)
    skip_draft? = Keyword.get(opts, :skip_draft, true)
    headers = HTTP.headers(config)
    req_opts = HTTP.req_opts(opts)

    with {:ok, pr} <- HTTP.fetch_pr(req, owner, repo, pr_number, headers, req_opts),
         {:ok, head_sha, draft?} <- pr_head(pr) do
      summarize_after_pr(req, owner, repo, headers, req_opts, head_sha, draft?, skip_draft?)
    end
  end

  defp summarize_after_pr(_req, _o, _r, _h, _ro, head_sha, true, true) do
    {:ok, draft_pending_summary(head_sha)}
  end

  defp summarize_after_pr(req, owner, repo, headers, req_opts, head_sha, draft?, _skip) do
    case fetch_all_check_runs(req, owner, repo, head_sha, headers, req_opts) do
      {:ok, runs} -> {:ok, classify(runs, head_sha, draft?)}
      error -> error
    end
  end

  defp draft_pending_summary(head_sha) do
    %{
      head_sha: head_sha,
      conclusion: :pending,
      draft: true,
      failed_names: [],
      summary: "draft PR — CI resume skipped",
      check_count: 0
    }
  end

  defp pr_head(pr) when is_map(pr) do
    head_sha = get_in(pr, ["head", "sha"])
    draft? = pr["draft"] == true

    if is_binary(head_sha) and head_sha != "" do
      {:ok, head_sha, draft?}
    else
      {:error, :missing_head_sha}
    end
  end

  @doc "Classify a list of check-run maps (GitHub API shape)."
  @spec classify([map()], String.t() | nil, boolean()) :: summary()
  def classify(runs, head_sha, draft? \\ false) when is_list(runs) do
    runs = Enum.map(runs, &normalize_run/1)
    failed = failed_names(runs)
    conclusion = conclusion_from(runs, failed)

    %{
      head_sha: head_sha,
      conclusion: conclusion,
      draft: draft?,
      failed_names: failed,
      summary: summary_text(conclusion, runs, failed),
      check_count: length(runs)
    }
  end

  defp normalize_run(run) when is_map(run) do
    %{
      name: bin_field(run, "name") || "unnamed",
      status: bin_field(run, "status"),
      conclusion: bin_field(run, "conclusion")
    }
  end

  defp bin_field(map, key) when is_map(map) and is_binary(key), do: Map.get(map, key)

  defp conclusion_from(runs, failed) do
    cond do
      Enum.any?(runs, &(&1.status != "completed")) -> :in_progress
      failed != [] -> :failed
      true -> :passed
    end
  end

  defp failed_names(runs) do
    for %{status: "completed", conclusion: c, name: n} <- runs,
        c in @fail_conclusions,
        do: n
  end

  defp summary_text(:failed, _runs, failed) do
    {shown, rest} = Enum.split(failed, 8)
    names = Enum.join(shown, ", ")
    more = if rest == [], do: "", else: " (+#{length(rest)} more)"
    "CI failed: #{names}#{more}"
  end

  defp summary_text(:in_progress, runs, _failed),
    do: "CI still running (#{length(runs)} check runs)"

  defp summary_text(:passed, [], _failed), do: "no check runs"
  defp summary_text(:passed, runs, _failed), do: "CI passed (#{length(runs)} checks)"

  defp fetch_all_check_runs(req, owner, repo, sha, headers, req_opts) do
    ctx = %{req: req, owner: owner, repo: repo, sha: sha, headers: headers, req_opts: req_opts}
    fetch_check_runs_page(ctx, 1, [])
  end

  defp fetch_check_runs_page(ctx, page, acc) do
    url = "#{HTTP.base_url()}/repos/#{ctx.owner}/#{ctx.repo}/commits/#{ctx.sha}/check-runs"
    params = %{filter: "latest", per_page: HTTP.page_size(), page: page}

    case ctx.req.get(url, [params: params, headers: ctx.headers] ++ ctx.req_opts) do
      {:ok, %{status: 200, body: body}} ->
        continue_or_done(ctx, page, acc, body)

      {:ok, %{status: 404}} ->
        {:ok, []}

      other ->
        HTTP.map_http_error(other, "check-runs")
    end
  end

  defp continue_or_done(ctx, page, acc, body) do
    runs = check_runs_from_body(body)
    total = total_count_from_body(body, runs)
    acc = acc ++ runs

    if more_pages?(acc, total, runs) do
      fetch_check_runs_page(ctx, page + 1, acc)
    else
      {:ok, acc}
    end
  end

  defp check_runs_from_body(body) when is_map(body) do
    body = HTTP.stringify_top_keys(body)
    body["check_runs"] || []
  end

  defp total_count_from_body(body, runs) when is_map(body) do
    body = HTTP.stringify_top_keys(body)
    body["total_count"] || length(runs)
  end

  defp more_pages?(acc, total, runs) do
    # Continue while GitHub says there are more and this page was full.
    length(acc) < total and HTTP.full_page?(runs)
  end
end
