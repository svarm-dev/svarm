defmodule Svarm.Tracker.GitHub.Normalize do
  @moduledoc """
  Converts GitHub REST API issue responses to `%Svarm.Issue{}` structs.

  GitHub issues have no native retry counter. `from_api_response/2` sets
  `attempts: 0`. `attach_attempts/1` overlays `task_coordination.attempts`
  (SQLite, not Orchestrator `retry_attempts`) onto the issue.

  GitHub has no native `depends_on`. Dispatch stores predecessor ids as
  `<!-- svarm-depends-on: id1,id2 -->` in the issue body. `from_api_response/2`
  parses that marker onto `Issue.depends_on` and strips it from `Issue.body`
  so Orchestrator `dependencies_met?/2` works even when `list_issues` later
  drops the body.
  """
  alias Svarm.{Coordination, Issue}

  @depends_on_marker ~r/<!--\s*svarm-depends-on:\s*([^>]*?)\s*-->/
  @follow_up_marker ~r/<!--\s*svarm-follow-up:\s*(.*?)\s*-->/s
  @max_depends_on 32
  @id_re ~r/^[A-Za-z0-9._:-]+$/

  @doc """
  Convert a GitHub API issue response to an Issue struct.
  Status is derived from labels per the tracker config.
  """
  def from_api_response(gh_issue, config) do
    labels = Map.get(gh_issue, "labels", []) |> Enum.map(& &1["name"])
    raw_body = gh_issue["body"] || ""
    depends_on = depends_on_from_body(raw_body)
    follow_up = follow_up_from_body(raw_body)

    %Issue{
      id: build_id(gh_issue),
      source_id: to_string(gh_issue["number"]),
      title: gh_issue["title"],
      body: strip_markers(raw_body),
      type: infer_type(labels),
      assignee: extract_assignee(gh_issue),
      status: map_status(labels, config),
      priority: 0,
      attempts: 0,
      created_by: gh_issue["user"]["login"] || "github",
      created_at: parse_created_at(gh_issue["created_at"]),
      tenant: gh_issue["repository_url"] |> String.split("/") |> Enum.at(-2) || "",
      labels: labels,
      depends_on: depends_on,
      follow_up: follow_up,
      tracker: :github,
      raw: gh_issue
    }
  end

  @doc """
  Parse `<!-- svarm-depends-on: id1,id2 -->` from a GitHub issue body.
  """
  @spec depends_on_from_body(String.t() | nil) :: [String.t()]
  def depends_on_from_body(body) when is_binary(body) do
    @depends_on_marker
    |> Regex.scan(body)
    |> Enum.flat_map(fn
      [_, csv] -> parse_dep_ids(csv)
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.take(@max_depends_on)
  end

  def depends_on_from_body(_), do: []

  @doc """
  Insert or replace the `svarm-depends-on` body marker. Empty `ids` removes it.
  """
  @spec put_depends_on_marker(String.t() | nil, [String.t()]) :: String.t()
  def put_depends_on_marker(body, ids) when is_list(ids) do
    stripped = strip_depends_on_marker(body || "")

    case ids
         |> Enum.map(&to_string/1)
         |> Enum.filter(&valid_dep_id?/1)
         |> Enum.uniq()
         |> Enum.take(@max_depends_on) do
      [] ->
        stripped

      kept ->
        marker = "<!-- svarm-depends-on: #{Enum.join(kept, ",")} -->"

        if stripped == "" do
          marker
        else
          stripped <> "\n\n" <> marker
        end
    end
  end

  @spec strip_depends_on_marker(String.t()) :: String.t()
  def strip_depends_on_marker(body) when is_binary(body) do
    body
    |> then(&Regex.replace(@depends_on_marker, &1, ""))
    |> String.trim_trailing()
  end

  defp parse_dep_ids(csv) when is_binary(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&valid_dep_id?/1)
  end

  defp valid_dep_id?(id) when is_binary(id) do
    byte_size(id) > 0 and byte_size(id) <= 128 and Regex.match?(@id_re, id)
  end

  defp valid_dep_id?(_), do: false

  @doc """
  Parse `<!-- svarm-follow-up: ... -->` from a GitHub issue body.

  Returns the trimmed text of the first marker, or nil. Like `depends_on`,
  this is sequencing metadata persisted as an HTML comment so it survives
  list/get and stays operator-visible and editable on GitHub.
  """
  @spec follow_up_from_body(String.t() | nil) :: String.t() | nil
  def follow_up_from_body(body) when is_binary(body) do
    case Regex.run(@follow_up_marker, body) do
      [_, text] ->
        text |> unescape_follow_up() |> String.trim() |> then(&if &1 == "", do: nil, else: &1)

      _ ->
        nil
    end
  end

  def follow_up_from_body(_), do: nil

  @doc """
  Insert or replace the `svarm-follow-up` body marker. `nil` / empty removes it.
  """
  @spec put_follow_up_marker(String.t() | nil, String.t() | nil) :: String.t()
  def put_follow_up_marker(body, text) do
    stripped = strip_follow_up_marker(body || "")
    put_follow_up_text(stripped, trim_marker_text(text))
  end

  defp trim_marker_text(text) when is_binary(text), do: String.trim(text)
  defp trim_marker_text(_), do: nil

  defp put_follow_up_text(stripped, text) when text in [nil, ""], do: stripped
  defp put_follow_up_text("", text), do: wrap_follow_up(text)
  defp put_follow_up_text(stripped, text), do: stripped <> "\n\n" <> wrap_follow_up(text)

  defp wrap_follow_up(text), do: "<!-- svarm-follow-up: #{escape_follow_up(text)} -->"

  # `-->` would close the HTML comment and leave the rest of the note as body.
  defp escape_follow_up(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("-->", "--&gt;")
  end

  defp unescape_follow_up(text) do
    text
    |> String.replace("--&gt;", "-->")
    |> String.replace("&amp;", "&")
  end

  @spec strip_follow_up_marker(String.t()) :: String.t()
  def strip_follow_up_marker(body) when is_binary(body) do
    body
    |> then(&Regex.replace(@follow_up_marker, &1, ""))
    |> String.trim_trailing()
  end

  def strip_follow_up_marker(_), do: ""

  @doc "Strip every Svärm body marker (depends_on + follow-up) for Issue.body."
  @spec strip_markers(String.t()) :: String.t()
  def strip_markers(body) when is_binary(body) do
    body |> strip_depends_on_marker() |> strip_follow_up_marker()
  end

  def strip_markers(_), do: ""

  @doc """
  Overlay stored retry attempts from coordination onto normalized issues.

  Missing rows stay `0`. Lists use one `get_many/1` (not N+1).
  """
  @spec attach_attempts(Issue.t()) :: Issue.t()
  @spec attach_attempts([Issue.t()]) :: [Issue.t()]
  def attach_attempts(%Issue{} = issue) do
    hd(attach_attempts([issue]))
  end

  def attach_attempts(issues) when is_list(issues) do
    by_id = Coordination.get_many(Enum.map(issues, & &1.id))

    Enum.map(issues, fn issue ->
      case Map.get(by_id, issue.id) do
        %{attempts: n} when is_integer(n) and n >= 0 -> %{issue | attempts: n}
        _ -> issue
      end
    end)
  end

  defp build_id(gh_issue) do
    # Use node_id for stability (survives issue number changes on transfer)
    Map.get(gh_issue, "node_id", "gh_#{gh_issue["number"]}")
  end

  defp extract_assignee(gh_issue) do
    case Map.get(gh_issue, "assignee") do
      %{"login" => login} -> login
      nil -> nil
      _ -> nil
    end
  end

  defp map_status(labels, config) do
    label_map = Map.get(config, :status_labels, %{})
    active_states = Map.get(config, :active_states, [])

    Enum.find_value(labels, &Map.get(label_map, &1)) || hd(active_states)
  end

  defp infer_type(labels) do
    cond do
      "research" in labels -> "research"
      "docs" in labels -> "docs"
      true -> "code"
    end
  end

  defp parse_created_at(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> 0
    end
  end

  defp parse_created_at(_), do: 0
end
