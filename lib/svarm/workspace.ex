defmodule Svarm.Workspace do
  @moduledoc """
  Per-issue workspace isolation (Symphony spec §9).

  - sanitize identifier to [A-Za-z0-9._-]
  - workspace path = <root>/<key>, must stay inside root
  - mkdir_p; report created_now
  """
  @default_root Path.join([System.tmp_dir!(), "svarm_workspaces"])

  def default_root, do: @default_root

  @doc """
  Returns {path, created_now}. Raises if the resolved path escapes root.
  """
  def ensure(identifier, root \\ @default_root) do
    key = sanitize(identifier)
    root_abs = Path.expand(root)
    path = Path.join(root_abs, key)
    abs = Path.expand(path)

    unless String.starts_with?(abs, root_abs <> "/") or abs == root_abs do
      raise "invalid_workspace_path: #{abs} escapes root #{root_abs}"
    end

    created_now = not File.dir?(abs)
    File.mkdir_p!(abs)
    {abs, created_now}
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
