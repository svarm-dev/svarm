defmodule Svarm.Coordination do
  @moduledoc """
  Durable per-task coordination state (PR link, CI resume counters, circuit).

  Lives in SQLite so it works for both Local and GitHub trackers without
  stuffing GitHub issue bodies. Owned by this context — not KanbanBridge.
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Svarm.Repo

  @primary_key false
  schema "task_coordination" do
    field(:task_id, :string, primary_key: true)
    field(:pr_url, :string)
    field(:pr_owner, :string)
    field(:pr_repo, :string)
    field(:pr_number, :integer)
    field(:ci_resume_count, :integer, default: 0)
    field(:ci_last_head_sha, :string)
    field(:ci_last_conclusion, :string)
    field(:ci_circuit_open, :boolean, default: false)
    field(:ci_context_summary, :string)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @castable [
    :pr_url,
    :pr_owner,
    :pr_repo,
    :pr_number,
    :ci_resume_count,
    :ci_last_head_sha,
    :ci_last_conclusion,
    :ci_circuit_open,
    :ci_context_summary
  ]

  @pr_url_re ~r{https://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)}i

  @doc "Fetch coordination for a task, or nil."
  @spec get(String.t()) :: t() | nil
  def get(task_id) when is_binary(task_id) do
    Repo.get(__MODULE__, task_id)
  end

  @doc """
  Upsert coordination fields for `task_id`.

  Partial maps merge onto existing row (or empty defaults).
  """
  @spec upsert(String.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def upsert(task_id, attrs) when is_binary(task_id) and is_map(attrs) do
    existing = get(task_id) || %__MODULE__{task_id: task_id}

    existing
    |> changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Record a PR association from a URL or structured fields.

  Accepts `pr_url` string and/or `pr_owner`/`pr_repo`/`pr_number`.
  Best-effort: invalid URLs return `{:error, :invalid_pr}`.

  Options:
  - `:owner` / `:repo` — when set (tracker config), reject PRs whose
    owner/repo do not match (case-insensitive). Prevents agent log
    decoy URLs from steering Checks polls to other repos.
  """
  @spec record_pr(String.t(), map() | String.t(), keyword()) ::
          {:ok, t()} | {:error, :invalid_pr | :repo_mismatch | Ecto.Changeset.t()}
  def record_pr(task_id, pr_or_attrs, opts \\ [])

  def record_pr(task_id, pr_url, opts) when is_binary(task_id) and is_binary(pr_url) do
    case parse_pr_url(pr_url) do
      {:ok, fields} ->
        with :ok <- match_repo_or_error(fields, opts), do: upsert(task_id, fields)

      :error ->
        {:error, :invalid_pr}
    end
  end

  def record_pr(task_id, attrs, opts) when is_binary(task_id) and is_map(attrs) do
    fields = attrs |> normalize_attrs() |> merge_parsed_pr_url()

    with :ok <- require_pr_fields(fields),
         :ok <- match_repo_or_error(fields, opts) do
      upsert(task_id, fields)
    end
  end

  defp merge_parsed_pr_url(%{pr_url: url} = fields) when is_binary(url) and url != "" do
    case parse_pr_url(url) do
      {:ok, parsed} -> Map.merge(fields, parsed)
      :error -> fields
    end
  end

  defp merge_parsed_pr_url(fields), do: fields

  defp require_pr_fields(%{pr_owner: o, pr_repo: r, pr_number: n})
       when is_binary(o) and is_binary(r) and is_integer(n),
       do: :ok

  defp require_pr_fields(_), do: {:error, :invalid_pr}

  defp match_repo_or_error(fields, opts) do
    if allowed_repo?(fields, opts), do: :ok, else: {:error, :repo_mismatch}
  end

  @doc "True when PR owner/repo match optional allowlist (tracker config)."
  @spec allowed_repo?(map(), keyword()) :: boolean()
  def allowed_repo?(_fields, []), do: true

  def allowed_repo?(fields, opts) when is_list(opts) do
    allowed_owner = Keyword.get(opts, :owner)
    allowed_repo = Keyword.get(opts, :repo)

    if is_nil(allowed_owner) and is_nil(allowed_repo) do
      true
    else
      owner = Map.get(fields, :pr_owner)
      repo = Map.get(fields, :pr_repo)
      eq_ignore?(owner, allowed_owner) and eq_ignore?(repo, allowed_repo)
    end
  end

  defp eq_ignore?(_actual, nil), do: true

  defp eq_ignore?(actual, expected) when is_binary(actual) and is_binary(expected) do
    String.downcase(actual) == String.downcase(expected)
  end

  defp eq_ignore?(_, _), do: false

  @doc "Parse a GitHub PR URL into owner/repo/number + url."
  @spec parse_pr_url(String.t()) :: {:ok, map()} | :error
  def parse_pr_url(url) when is_binary(url) do
    case Regex.run(@pr_url_re, url) do
      [full, owner, repo, number] ->
        {:ok,
         %{
           pr_url: full,
           pr_owner: owner,
           pr_repo: repo,
           pr_number: String.to_integer(number)
         }}

      _ ->
        :error
    end
  end

  @doc """
  Extract the first GitHub PR URL from free text (agent log / summary).
  """
  @spec extract_pr_url(String.t() | nil) :: String.t() | nil
  def extract_pr_url(nil), do: nil

  def extract_pr_url(text) when is_binary(text) do
    case Regex.run(@pr_url_re, text) do
      [full | _] -> full
      _ -> nil
    end
  end

  @doc """
  Rows with a PR number that are eligible for CI resume polling.

  Skips circuit-open tasks. Bound by caller (orchestrator max/tick).
  """
  @spec list_with_pr(keyword()) :: [t()]
  def list_with_pr(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    include_circuit = Keyword.get(opts, :include_circuit_open, false)

    __MODULE__
    |> where([c], not is_nil(c.pr_number) and not is_nil(c.pr_owner) and not is_nil(c.pr_repo))
    |> then(fn q ->
      if include_circuit, do: q, else: where(q, [c], c.ci_circuit_open == false)
    end)
    |> order_by([c], asc: c.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "True when circuit is open for this task."
  @spec circuit_open?(String.t()) :: boolean()
  def circuit_open?(task_id) when is_binary(task_id) do
    case get(task_id) do
      %{ci_circuit_open: true} -> true
      _ -> false
    end
  end

  defp changeset(row, attrs) do
    row
    |> cast(normalize_attrs(attrs), @castable)
    |> validate_number(:ci_resume_count, greater_than_or_equal_to: 0)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    allowed = Map.new(@castable, fn k -> {Atom.to_string(k), k} end)

    Enum.reduce(attrs, %{}, fn
      {k, v}, acc when is_atom(k) and k in @castable ->
        Map.put(acc, k, v)

      {k, v}, acc when is_binary(k) ->
        case Map.fetch(allowed, k) do
          {:ok, atom} -> Map.put(acc, atom, v)
          :error -> acc
        end

      _, acc ->
        acc
    end)
  end
end
