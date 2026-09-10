defmodule Svarm.Workflow.Config do
  @moduledoc "Typed getters from workflow front matter (Symphony config layer)."

  require Logger

  alias Svarm.Workflow.Render
  alias Svarm.Workspace

  @doc false
  def from(%{config: config}) when is_map(config), do: from_map(config)
  def from(_), do: from_map(%{})

  @doc false
  def from_map(config) when is_map(config) do
    %{
      poll_interval_ms: get_int(config, ["polling", "interval_ms"], 30_000),
      workspace_root: get_string(config, ["workspace", "root"], Workspace.default_root()),
      workspace_isolation: workspace_isolation(config),
      workspace_git_repo: workspace_git_repo(config),
      active_states: get_list(config, ["tracker", "active_states"], ["todo", "in_progress"]),
      terminal_states:
        get_list(config, ["tracker", "terminal_states"], ["done", "failed", "review"]),
      max_concurrent: get_int(config, ["agent", "max_concurrent_agents"], 3),
      max_retry_backoff_ms: get_int(config, ["agent", "max_retry_backoff_ms"], 300_000),
      stall_timeout_ms: get_int(config, ["agent", "stall_timeout_ms"], 2_700_000),
      tracker_config: tracker_config(config)
    }
    |> Map.update!(:workspace_root, &expand_path/1)
  end

  @doc "Symphony §6.3 — orchestrator must not dispatch when config is invalid."
  def validate_workflow(%Svarm.Workflow{} = wf) do
    cfg = from(wf)
    pending = Svarm.Approval.pending_status()

    cond do
      wf.prompt_template == "" ->
        {:error, :empty_prompt_template}

      Render.validate(wf.prompt_template) != :ok ->
        {:error, :invalid_prompt_template}

      cfg.active_states == [] ->
        {:error, :empty_active_states}

      pending in cfg.active_states ->
        {:error, :pending_approval_in_active_states}

      cfg.poll_interval_ms < 1_000 ->
        {:error, :poll_interval_too_low}

      match?({:error, :invalid_workspace_isolation}, cfg.workspace_isolation) ->
        Logger.warning(
          "workflow: invalid workspace.isolation #{inspect(isolation_raw(wf))}; expected path or worktree"
        )

        {:error, :invalid_workspace_isolation}

      true ->
        validate_tracker_config(cfg.tracker_config)
    end
  end

  defp validate_tracker_config(t) when is_map(t) do
    with :ok <- validate_github_fields(t),
         :ok <- validate_label_map_field(t[:status_labels]) do
      validate_label_map_field(t[:reverse_labels])
    end
  end

  defp validate_github_fields(%{kind: :github} = t) do
    cond do
      blank?(t[:owner]) or blank?(t[:repo]) ->
        {:error, :github_tracker_missing_owner_or_repo}

      t[:auth] == :app and (blank?(t[:app_id]) or blank_app_key?(t)) ->
        {:error, :github_app_auth_incomplete}

      true ->
        :ok
    end
  end

  defp validate_github_fields(_), do: :ok

  defp validate_label_map_field({:error, reason}), do: {:error, reason}
  defp validate_label_map_field(_), do: :ok

  defp blank_app_key?(t) do
    blank?(t[:private_key]) and blank?(t[:private_key_path])
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # Omitted → :path. Only the exact strings "path" and "worktree" are valid.
  defp workspace_isolation(config) do
    case get_in_path(config, ["workspace", "isolation"]) do
      nil -> :path
      "path" -> :path
      "worktree" -> :worktree
      _other -> {:error, :invalid_workspace_isolation}
    end
  end

  defp isolation_raw(%{config: config}) when is_map(config),
    do: get_in_path(config, ["workspace", "isolation"])

  defp isolation_raw(_), do: nil

  defp workspace_git_repo(config) do
    case get_string(config, ["workspace", "git_repo"], nil) do
      path when is_binary(path) and path != "" -> expand_path(path)
      _ -> nil
    end
  end

  @doc """
  Parses the tracker config from workflow front matter.
  Returns a map with adapter-agnostic fields plus adapter-specific extras.
  """
  def tracker_config(config) when is_map(config) do
    tracker =
      case Map.get(config, "tracker", %{}) do
        map when is_map(map) -> map
        _ -> %{}
      end

    kind = get_string(tracker, ["kind"], "local") |> String.to_existing_atom()

    base =
      %{
        kind: kind,
        active_states: get_list(tracker, ["active_states"], ["todo", "in_progress"]),
        terminal_states: get_list(tracker, ["terminal_states"], ["done", "failed", "review"])
      }
      |> maybe_put_label_map(
        :status_labels,
        parse_label_map(tracker, "status_labels", :invalid_tracker_status_labels)
      )
      |> maybe_put_label_map(
        :reverse_labels,
        parse_label_map(tracker, "reverse_labels", :invalid_tracker_reverse_labels)
      )

    case kind do
      :github ->
        api_key_env = get_string(tracker, ["api_key"], "GITHUB_TOKEN")
        auth = parse_auth(get_string(tracker, ["auth"], "token"))

        Map.merge(base, %{
          owner: get_string(tracker, ["owner"], nil),
          repo: get_string(tracker, ["repo"], nil),
          auth: auth,
          api_key: resolve_env(api_key_env),
          app_id:
            resolve_env_or_literal(get_string(tracker, ["app_id"], nil), "SVARM_GITHUB_APP_ID"),
          installation_id:
            resolve_env_or_literal(
              get_string(tracker, ["installation_id"], nil),
              "SVARM_GITHUB_INSTALLATION_ID"
            ),
          private_key_path:
            resolve_env_or_literal(
              get_string(tracker, ["private_key_path"], nil),
              "SVARM_GITHUB_APP_KEY_PATH"
            ),
          private_key: System.get_env("SVARM_GITHUB_APP_PRIVATE_KEY"),
          required_labels: get_list(tracker, ["required_labels"], []),
          agent_assignees: get_list(tracker, ["agent_assignees"], [])
        })

      :local ->
        Map.put(base, :ignored_assignees, [])

      _ ->
        base
    end
  end

  # -- private helpers --

  defp resolve_env("$" <> var), do: System.get_env(var)
  defp resolve_env(var) when is_binary(var), do: System.get_env(var)
  defp resolve_env(nil), do: nil

  # `$ENV` → env value; bare value → literal (or default env when missing from WORKFLOW)
  defp resolve_env_or_literal(nil, default_env), do: System.get_env(default_env)
  defp resolve_env_or_literal("$" <> var, _default_env), do: System.get_env(var)
  defp resolve_env_or_literal(value, _default_env) when is_binary(value), do: value

  defp parse_auth("app"), do: :app
  defp parse_auth(_), do: :token

  # nil = omitted (adapter defaults). {:error, reason} = fail closed at validate.
  defp parse_label_map(tracker, key, invalid_reason) when is_map(tracker) do
    case Map.get(tracker, key) do
      nil -> nil
      map when is_map(map) -> decode_label_map(map, invalid_reason)
      _other -> {:error, invalid_reason}
    end
  end

  defp decode_label_map(map, invalid_reason) do
    case valid_label_map?(map) do
      true -> Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
      false -> {:error, invalid_reason}
    end
  end

  defp valid_label_map?(map) when is_map(map) do
    Enum.all?(map, fn {k, v} -> label_map_string?(k) and label_map_string?(v) end)
  end

  defp label_map_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp label_map_string?(_), do: false

  defp maybe_put_label_map(map, _key, nil), do: map
  defp maybe_put_label_map(map, key, value), do: Map.put(map, key, value)

  defp get_int(map, path, default) do
    case get_in_path(map, path) do
      n when is_integer(n) ->
        n

      n when is_binary(n) ->
        case Integer.parse(n),
          do: (
            {i, _} -> i
            _ -> default
          )

      _ ->
        default
    end
  end

  defp get_string(map, path, default) do
    case get_in_path(map, path) do
      s when is_binary(s) and s != "" -> s
      _ -> default
    end
  end

  defp get_list(map, path, default) do
    case get_in_path(map, path) do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> default
    end
  end

  defp get_in_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, val} -> get_in_path(val, rest)
      :error -> nil
    end
  end

  defp get_in_path(val, []), do: val
  defp get_in_path(_, _), do: nil

  defp expand_path("~" <> rest), do: Path.expand("~#{rest}")
  defp expand_path(path), do: Path.expand(path)
end
