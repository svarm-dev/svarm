defmodule Svarm.Workspace do
  @moduledoc """
  Per-issue workspace isolation (Symphony spec §9).

  Modes (WORKFLOW `workspace.isolation`):

  - `:path` (default) — directory under the workspace root with a path-escape guard
  - `:worktree` — `git worktree add` under the root from a configured source repo

  Worktrees are **not** a container/VM sandbox — they isolate git working trees only.
  See SECURITY.md.
  """
  @default_root Path.join([System.tmp_dir!(), "svarm_workspaces"])

  def default_root, do: @default_root

  @doc """
  Ensure a workspace for `identifier` under `root`.

  Options:
  - `:isolation` — `:path` (default) or `:worktree`
  - `:git_repo` — absolute path to the source git repo (required for `:worktree`)

  Returns `{:ok, {path, created_now}}` or `{:error, reason}`.
  """
  def ensure(identifier, root \\ @default_root, opts \\ [])

  def ensure(identifier, root, opts) when is_binary(identifier) and is_list(opts) do
    isolation = isolation_mode(Keyword.get(opts, :isolation, :path))

    with {:ok, abs, root_abs, key} <- resolve_path(identifier, root) do
      case isolation do
        :path -> ensure_path(abs, root_abs)
        :worktree -> ensure_worktree(abs, root_abs, key, opts)
      end
    end
  end

  @doc """
  Legacy bang API used by runners: returns `{path, created_now}` or raises.

  Prefer `ensure/3` with tagged tuples for new call sites.
  """
  def ensure!(identifier, root \\ @default_root, opts \\ []) do
    case ensure(identifier, root, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "workspace_ensure_failed: #{inspect(reason)}"
    end
  end

  defp isolation_mode(:worktree), do: :worktree
  defp isolation_mode("worktree"), do: :worktree
  defp isolation_mode(_), do: :path

  defp resolve_path(identifier, root) do
    key = sanitize(identifier)
    root_abs = Path.expand(root)
    path = Path.join(root_abs, key)
    abs = Path.expand(path)

    if String.starts_with?(abs, root_abs <> "/") or abs == root_abs do
      {:ok, abs, root_abs, key}
    else
      {:error, {:path_escape, abs, root_abs}}
    end
  end

  defp ensure_path(abs, _root_abs) do
    created_now = not File.dir?(abs)

    case File.mkdir_p(abs) do
      :ok -> {:ok, {abs, created_now}}
      {:error, reason} -> {:error, {:mkdir, reason}}
    end
  end

  defp ensure_worktree(abs, _root_abs, key, opts) do
    repo = opts |> Keyword.get(:git_repo) |> normalize_repo()

    cond do
      is_nil(repo) ->
        {:error, :git_repo_required}

      not File.dir?(repo) ->
        {:error, {:git_repo_missing, repo}}

      not File.dir?(Path.join(repo, ".git")) and not File.regular?(Path.join(repo, ".git")) ->
        {:error, {:not_a_git_repo, repo}}

      File.dir?(abs) ->
        {:ok, {abs, false}}

      true ->
        add_worktree(repo, abs, key)
    end
  end

  defp normalize_repo(nil), do: nil
  defp normalize_repo(""), do: nil
  defp normalize_repo(path) when is_binary(path), do: Path.expand(path)
  defp normalize_repo(_), do: nil

  defp add_worktree(repo, abs, key) do
    branch = "svarm/" <> key
    # Shell-out is intentional for git worktree (not agent Port.open).
    args = ["-C", repo, "worktree", "add", "-B", branch, abs]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} ->
        {:ok, {abs, true}}

      {out, code} ->
        {:error, {:git_worktree_failed, code, String.trim(out)}}
    end
  end

  def sanitize(identifier) when is_binary(identifier) do
    identifier
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unnamed"
      other -> other
    end
  end

  @doc """
  Returns a stable workspace identifier for an issue or task.

  Prefers the tracker-native `source_id` (e.g. GitHub issue number) when
  available, falling back to the internal `id`. This keeps workspaces
  human-friendly while remaining unique per tracker.
  """
  def key_for_issue(issue) when is_map(issue) do
    Map.get(issue, :source_id) || Map.get(issue, :id) || "unknown"
  end

  def key_for_issue(_), do: "unknown"
end
