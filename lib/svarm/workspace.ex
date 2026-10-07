defmodule Svarm.Workspace do
  @moduledoc """
  Per-issue workspace isolation (Symphony spec §9).

  Modes (WORKFLOW `workspace.isolation`):

  - `:path` (default) — directory under the workspace root with a path-escape guard
  - `:worktree` — `git worktree add` under the root from a configured source repo
  - `:clone` — `git clone` from a separate remote URL (e.g. a Forgejo repo).
    Selected automatically when `workspace.git_remote` is set and
    `workspace.isolation` is omitted (or `path`). Plain `git`, no `gh`.

  Worktrees are **not** a container/VM sandbox — they isolate git working trees only.
  See SECURITY.md.

  Git add/list/remove share a bounded helper (`:git_timeout_ms`, default 30s).
  Overtime returns `{:error, :git_timeout}` after best-effort leftover cleanup.
  `cleanup/3` runs `git worktree remove` so trees do not leak in `git worktree list`.
  """
  @default_root Path.join([System.tmp_dir!(), "svarm_workspaces"])
  @default_git_timeout_ms 30_000

  require Logger

  def default_root, do: @default_root

  @doc """
  Ensure a workspace for `identifier` under `root`.

  Options:
  - `:isolation` — `:path` (default), `:worktree`, or `:clone`
  - `:git_repo` — absolute path to the source git repo (required for `:worktree`)
  - `:git_remote` — remote URL to clone (required for `:clone`)
  - `:git_token` — optional token for `:clone`; used as the HTTPS password and
    left as `GIT_TOKEN` in the agent env (never written to `.git/config`)
  - `:git_timeout_ms` — bound for git add/list/clone (default 30_000)
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
        :clone -> ensure_clone(abs, root_abs, opts)
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
        :clone -> cleanup_path(abs)
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
  defp isolation_mode(:clone), do: {:ok, :clone}
  defp isolation_mode("clone"), do: {:ok, :clone}
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

  # `:clone` — fresh `git clone` from the configured remote. A matching
  # existing clone is reused; anything else under the ticket path is cleared
  # (bounded to `root_abs`) and re-cloned so a partial run self-heals.
  defp ensure_clone(abs, root_abs, opts) do
    remote = opts |> Keyword.get(:git_remote) |> normalize_remote()
    token = opts |> Keyword.get(:git_token) |> normalize_token()

    cond do
      is_nil(remote) ->
        {:error, :git_remote_required}

      clone_matches?(abs, remote, opts) ->
        {:ok, {abs, false}}

      File.exists?(abs) ->
        with :ok <- bounded_rm_rf(abs, root_abs) do
          clone_into(abs, root_abs, remote, token, opts)
        end

      true ->
        clone_into(abs, root_abs, remote, token, opts)
    end
  end

  defp clone_into(abs, root_abs, remote, token, opts) do
    parent = Path.dirname(abs)
    clone_url = authenticated_remote(remote, token)

    case git_cmd(parent, ["clone", clone_url, abs], opts) do
      {:ok, _out} ->
        case configure_clone(abs, remote, token, opts) do
          :ok ->
            {:ok, {abs, true}}

          {:error, reason} ->
            discard_clone(abs, root_abs, token)
            {:error, normalize_clone_error(reason, token)}
        end

      {:error, reason} ->
        discard_clone(abs, root_abs, token)
        {:error, normalize_clone_error(reason, token)}
    end
  end

  # Keep `origin` clean (token never lands in `.git/config`). When a token was
  # used, leave a credential helper that reads `GIT_TOKEN` at push time; the
  # runner injects that var into the agent env. A failed reset is an error so
  # the caller can drop the tree instead of leaving the token in origin.
  defp configure_clone(abs, remote, token, opts) do
    with :ok <- git_ok(git_cmd(abs, ["remote", "set-url", "origin", remote], opts)) do
      maybe_credential_helper(abs, token, opts)
    end
  end

  defp maybe_credential_helper(_abs, token, _opts) when not is_binary(token), do: :ok

  defp maybe_credential_helper(abs, _token, opts) do
    git_ok(git_cmd(abs, ["config", "--local", "credential.helper", credential_helper()], opts))
  end

  defp git_ok({:ok, _}), do: :ok
  defp git_ok({:error, reason}), do: {:error, reason}

  # Scrub first so a failed delete still does not leave the token in config.
  defp discard_clone(abs, root_abs, token) do
    _ = scrub_clone_token(abs, token)
    _ = bounded_rm_rf(abs, root_abs)
    :ok
  end

  defp scrub_clone_token(abs, token) when is_binary(token) and token != "" do
    config = Path.join(abs, ".git/config")

    if File.regular?(config) do
      scrubbed = config |> File.read!() |> redact_token(token)
      File.write!(config, scrubbed)
    end

    :ok
  rescue
    e in [File.Error] ->
      Logger.warning("workspace: could not scrub clone token: #{Exception.message(e)}")
      :ok
  end

  defp scrub_clone_token(_abs, _token), do: :ok

  defp credential_helper do
    ~s|!f() { echo username=oauth2; echo "password=$GIT_TOKEN"; }; f|
  end

  defp clone_matches?(abs, remote, opts) do
    if File.dir?(Path.join(abs, ".git")) do
      case git_cmd(abs, ["remote", "get-url", "origin"], opts) do
        {:ok, out} -> String.trim(out) == remote
        _ -> false
      end
    else
      false
    end
  end

  defp normalize_clone_error({:git_failed, code, out}, token) do
    {:git_clone_failed, code, redact_git_output(out, token)}
  end

  defp normalize_clone_error(reason, _token), do: reason

  defp redact_git_output(out, token) when is_binary(out) do
    out
    |> redact_token(token)
    |> Svarm.Redact.text()
  end

  defp redact_token(out, token) when is_binary(token) and token != "" do
    encoded = URI.encode(token, &URI.char_unreserved?/1)

    out
    |> String.replace(token, "[redacted]")
    |> String.replace(encoded, "[redacted]")
  end

  defp redact_token(out, _token), do: out

  # HTTPS remotes get `oauth2:<token>` userinfo for the clone only; the URL is
  # reset to the clean form right after. SSH and non-HTTPS remotes are untouched.
  defp authenticated_remote(remote, token) when is_binary(token) do
    case URI.parse(remote) do
      %URI{scheme: "https", host: host} = uri when is_binary(host) ->
        encoded = URI.encode(token, &URI.char_unreserved?/1)
        URI.to_string(%{uri | userinfo: "oauth2:" <> encoded})

      _ ->
        remote
    end
  end

  defp authenticated_remote(remote, _token), do: remote

  defp normalize_remote(nil), do: nil

  defp normalize_remote(remote) when is_binary(remote) do
    case String.trim(remote) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_remote(_), do: nil

  defp normalize_token(token) when is_binary(token) do
    case String.trim(token) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_token(_), do: nil

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
