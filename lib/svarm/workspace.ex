defmodule Svarm.Workspace do
  @moduledoc """
  Per-issue workspace isolation (Symphony spec §9).

  Modes (WORKFLOW `workspace.isolation`):

  - `:path` (default) — directory under the workspace root with a path-escape guard
  - `:worktree` — `git worktree add` under the root from a configured source repo

  Worktrees are **not** a container/VM sandbox — they isolate git working trees only.
  See SECURITY.md.

  Git add/list/remove share a bounded helper (`:git_timeout_ms`, default 30s).
  Overtime returns `{:error, :git_timeout}` after best-effort leftover cleanup.
  `cleanup/3` runs `git worktree remove` so trees do not leak in `git worktree list`.
  """
  @default_root Path.join([System.tmp_dir!(), "svarm_workspaces"])
  @default_git_timeout_ms 30_000

  def default_root, do: @default_root

  @doc """
  Ensure a workspace for `identifier` under `root`.

  Options:
  - `:isolation` — `:path` (default) or `:worktree`
  - `:git_repo` — absolute path to the source git repo (required for `:worktree`)
  - `:git_timeout_ms` — bound for git add/list (default 30_000)
  - `:git` — git executable (default `"git"`)

  Returns `{:ok, {path, created_now}}` or `{:error, reason}`.
  """
  def ensure(identifier, root \\ @default_root, opts \\ [])

  def ensure(identifier, root, opts) when is_binary(identifier) and is_list(opts) do
    with {:ok, isolation} <- isolation_mode(Keyword.get(opts, :isolation, :path)),
         {:ok, abs, root_abs, key} <- resolve_path(identifier, root) do
      case isolation do
        :path -> ensure_path(abs)
        :worktree -> ensure_worktree(abs, root_abs, key, opts)
      end
    end
  end

  @doc """
  Remove a workspace created by `ensure/3`.

  `:path` deletes the directory (still root-bounded).
  `:worktree` runs `git worktree remove` against the configured source repo
  so `git worktree list` no longer includes the ticket path.

  Options match `ensure/3` (`:isolation`, `:git_repo`, `:git_timeout_ms`, `:git`).
  """
  def cleanup(identifier, root \\ @default_root, opts \\ [])

  def cleanup(identifier, root, opts) when is_binary(identifier) and is_list(opts) do
    with {:ok, isolation} <- isolation_mode(Keyword.get(opts, :isolation, :path)),
         {:ok, abs, _root_abs, _key} <- resolve_path(identifier, root) do
      case isolation do
        :path -> cleanup_path(abs)
        :worktree -> cleanup_worktree(abs, opts)
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

  defp isolation_mode(:worktree), do: {:ok, :worktree}
  defp isolation_mode("worktree"), do: {:ok, :worktree}
  defp isolation_mode(:path), do: {:ok, :path}
  defp isolation_mode("path"), do: {:ok, :path}
  defp isolation_mode(nil), do: {:ok, :path}
  defp isolation_mode(_), do: {:error, :invalid_workspace_isolation}

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

  defp ensure_path(abs) do
    created_now = not File.dir?(abs)

    case File.mkdir_p(abs) do
      :ok -> {:ok, {abs, created_now}}
      {:error, reason} -> {:error, {:mkdir, reason}}
    end
  end

  defp cleanup_path(abs) do
    case File.rm_rf(abs) do
      {:ok, _} -> :ok
      {:error, reason, _file} -> {:error, {:rm, reason}}
    end
  end

  defp ensure_worktree(abs, root_abs, key, opts) do
    repo = opts |> Keyword.get(:git_repo) |> normalize_repo()

    cond do
      is_nil(repo) ->
        {:error, :git_repo_required}

      not File.dir?(repo) ->
        {:error, {:git_repo_missing, repo}}

      not File.dir?(Path.join(repo, ".git")) and not File.regular?(Path.join(repo, ".git")) ->
        {:error, {:not_a_git_repo, repo}}

      File.dir?(abs) ->
        reuse_or_recreate_worktree(repo, abs, root_abs, key, opts)

      true ->
        add_worktree(repo, abs, root_abs, key, opts)
    end
  end

  defp reuse_or_recreate_worktree(repo, abs, root_abs, key, opts) do
    case linked_worktree?(repo, abs, opts) do
      {:ok, true} ->
        {:ok, {abs, false}}

      {:ok, false} ->
        recreate_if_not_foreign(repo, abs, root_abs, key, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recreate_if_not_foreign(repo, abs, root_abs, key, opts) do
    case foreign_worktree?(repo, abs, opts) do
      {:ok, true} ->
        {:error, {:not_a_worktree, abs}}

      {:ok, false} ->
        with :ok <- clear_leftover_worktree_path(repo, abs, root_abs, opts) do
          add_worktree(repo, abs, root_abs, key, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_worktree(abs, opts) do
    repo = opts |> Keyword.get(:git_repo) |> normalize_repo()

    cond do
      is_nil(repo) ->
        {:error, :git_repo_required}

      not File.dir?(repo) ->
        {:error, {:git_repo_missing, repo}}

      not File.dir?(Path.join(repo, ".git")) and not File.regular?(Path.join(repo, ".git")) ->
        {:error, {:not_a_git_repo, repo}}

      true ->
        remove_worktree(repo, abs, opts)
    end
  end

  defp remove_worktree(repo, abs, opts) do
    case linked_worktree?(repo, abs, opts) do
      {:ok, false} ->
        if File.exists?(abs) do
          {:error, {:not_a_worktree, abs}}
        else
          :ok
        end

      {:ok, true} ->
        do_remove_worktree(repo, abs, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_remove_worktree(repo, abs, opts) do
    case git_cmd(repo, ["worktree", "remove", abs], opts) do
      {:ok, _} ->
        :ok

      {:error, :git_timeout} = timeout ->
        timeout

      {:error, _} ->
        force_remove_worktree(repo, abs, opts)
    end
  end

  defp force_remove_worktree(repo, abs, opts) do
    case git_cmd(repo, ["worktree", "remove", "--force", abs], opts) do
      {:ok, _} -> :ok
      {:error, :git_timeout} = timeout -> timeout
      {:error, {:git_failed, code, out}} -> {:error, {:git_worktree_failed, code, out}}
    end
  end

  # `git worktree list` from the configured repo — path-mode leftovers and
  # foreign checkouts must not count as isolation.
  defp linked_worktree?(repo, abs, opts) do
    case git_cmd(repo, ["worktree", "list", "--porcelain"], opts) do
      {:ok, out} ->
        listed? =
          out
          |> String.split("\n", trim: true)
          |> Enum.any?(fn
            "worktree " <> path -> Path.expand(path) == abs
            _ -> false
          end)

        {:ok, listed?}

      {:error, :git_timeout} = timeout ->
        timeout

      {:error, _} ->
        {:ok, false}
    end
  end

  defp normalize_repo(nil), do: nil
  defp normalize_repo(""), do: nil
  defp normalize_repo(path) when is_binary(path), do: Path.expand(path)
  defp normalize_repo(_), do: nil

  defp add_worktree(repo, abs, root_abs, key, opts) do
    branch = "svarm/" <> key

    case git_cmd(repo, ["worktree", "add", "-B", branch, abs], opts) do
      {:ok, _} ->
        {:ok, {abs, true}}

      {:error, {:git_failed, code, out}} ->
        _ = clear_leftover_worktree_path(repo, abs, root_abs, opts)
        {:error, {:git_worktree_failed, code, out}}

      {:error, reason} ->
        _ = clear_leftover_worktree_path(repo, abs, root_abs, opts)
        {:error, reason}
    end
  end

  # Best-effort: drop a partial `git worktree add` so the next `ensure` is not
  # stuck on `{:not_a_worktree, abs}`. Never deletes outside `root_abs`.
  defp clear_leftover_worktree_path(repo, abs, root_abs, opts) do
    _ = git_cmd(repo, ["worktree", "remove", "--force", abs], opts)
    _ = git_cmd(repo, ["worktree", "prune"], opts)
    bounded_rm_rf(abs, root_abs)
  end

  defp bounded_rm_rf(abs, root_abs) do
    cond do
      not (String.starts_with?(abs, root_abs <> "/") and abs != root_abs) ->
        {:error, {:path_escape, abs, root_abs}}

      not File.exists?(abs) ->
        :ok

      true ->
        case File.rm_rf(abs) do
          {:ok, _} -> :ok
          {:error, reason, _file} -> {:error, {:rm, reason}}
        end
    end
  end

  # Linked to a different repo (or a non-worktree checkout with its own `.git`).
  defp foreign_worktree?(repo, abs, opts) do
    if File.exists?(Path.join(abs, ".git")) do
      with {:ok, abs_common} <- git_common_dir(abs, opts),
           {:ok, repo_common} <- git_common_dir(repo, opts) do
        {:ok, abs_common != repo_common}
      else
        {:error, :git_timeout} = timeout -> timeout
        {:error, _} -> {:ok, false}
      end
    else
      {:ok, false}
    end
  end

  defp git_common_dir(dir, opts) do
    case git_cmd(dir, ["rev-parse", "--git-common-dir"], opts) do
      {:ok, out} ->
        common =
          out
          |> String.trim()
          |> Path.expand(dir)
          |> String.trim_trailing("/")

        {:ok, common}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp git_cmd(repo, subargs, opts) when is_list(subargs) and is_list(opts) do
    timeout = Keyword.get(opts, :git_timeout_ms, @default_git_timeout_ms)
    exe = git_executable(Keyword.get(opts, :git, "git"))

    cond do
      not is_binary(exe) ->
        {:error, :git_not_found}

      not is_integer(timeout) or timeout < 0 ->
        {:error, :git_timeout}

      true ->
        run_git(exe, ["-C", repo | subargs], timeout)
    end
  end

  defp git_executable(path) when is_binary(path) do
    if String.contains?(path, "/") do
      Path.expand(path)
    else
      System.find_executable(path)
    end
  end

  defp git_executable(_), do: nil

  # Bounded git: Port + deadline. System.cmd/3 has no timeout on Elixir 1.20.
  defp run_git(exe, args, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, exe},
        [:binary, :exit_status, :stderr_to_stdout, :hide, args: args]
      )

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_git_port(port, deadline, [])
  end

  defp collect_git_port(port, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      abandon_git_port(port)
    else
      receive do
        {^port, {:data, data}} ->
          collect_git_port(port, deadline, [acc, data])

        {^port, {:exit_status, 0}} ->
          {:ok, IO.iodata_to_binary(acc)}

        {^port, {:exit_status, code}} ->
          {:error, {:git_failed, code, String.trim(IO.iodata_to_binary(acc))}}
      after
        remaining ->
          abandon_git_port(port)
      end
    end
  end

  defp abandon_git_port(port) do
    kill_git_port(port)
    drain_git_port(port)
    {:error, :git_timeout}
  end

  defp kill_git_port(port) do
    case Port.info(port) do
      info when is_list(info) ->
        case Keyword.get(info, :os_pid) do
          pid when is_integer(pid) ->
            _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

          _ ->
            :ok
        end

        case Port.info(port) do
          info2 when is_list(info2) -> Port.close(port)
          nil -> :ok
        end

      nil ->
        :ok
    end

    :ok
  end

  defp drain_git_port(port) do
    receive do
      {^port, _} -> drain_git_port(port)
    after
      0 -> :ok
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
