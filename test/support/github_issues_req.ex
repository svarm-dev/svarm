defmodule Svarm.Test.GitHubIssuesReq do
  @moduledoc false
  # In-memory GitHub Issues REST stub for Dispatch/create/depends_on tests.
  # Keys: {:issue, number} payloads, :seq, :posts.

  @table :svarm_github_issues_req

  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _ -> :ok
    end
  end

  def reset! do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ets.insert(@table, {:seq, 0})
    :ets.insert(@table, {:posts, []})
    :ok
  end

  def posts do
    ensure_table!()

    case :ets.lookup(@table, :posts) do
      [{:posts, list}] -> Enum.reverse(list)
      [] -> []
    end
  end

  def issues do
    ensure_table!()

    @table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{:issue, _n}, payload} -> [payload]
      _ -> []
    end)
    |> Enum.sort_by(& &1["number"])
  end

  def get_issue(number) when is_integer(number) do
    ensure_table!()

    case :ets.lookup(@table, {:issue, number}) do
      [{{:issue, ^number}, payload}] -> payload
      [] -> nil
    end
  end

  def seed(payload) when is_map(payload) do
    ensure_table!()
    number = payload["number"]
    :ets.insert(@table, {{:issue, number}, payload})
    bump_seq(number)
    payload
  end

  def get(url, opts) do
    ensure_table!()

    cond do
      String.ends_with?(url, "/comments") ->
        {:ok, %{status: 200, body: []}}

      match?({_n, ""}, Integer.parse(Path.basename(url))) ->
        {n, ""} = Integer.parse(Path.basename(url))

        case get_issue(n) do
          nil -> {:ok, %{status: 404, body: %{}}}
          payload -> {:ok, %{status: 200, body: payload}}
        end

      true ->
        state = opts |> Keyword.get(:params, %{}) |> Map.get(:state)
        body = listed_issues(state)
        {:ok, %{status: 200, body: body}}
    end
  end

  def post(url, opts) do
    ensure_table!()
    json = Keyword.get(opts, :json, %{})
    record_post(url, json)

    if String.ends_with?(url, "/comments") do
      {:ok, %{status: 201, body: %{}}}
    else
      n = next_number()
      payload = issue_from_create(n, json)
      :ets.insert(@table, {{:issue, n}, payload})
      {:ok, %{status: 201, body: payload}}
    end
  end

  def patch(url, opts) do
    ensure_table!()
    json = Keyword.get(opts, :json, %{})

    case Integer.parse(Path.basename(url)) do
      {n, ""} ->
        case get_issue(n) do
          nil ->
            {:ok, %{status: 404, body: %{}}}

          current ->
            updated = apply_patch(current, json)
            :ets.insert(@table, {{:issue, n}, updated})
            {:ok, %{status: 200, body: updated}}
        end

      _ ->
        {:ok, %{status: 200, body: %{}}}
    end
  end

  defp listed_issues("open"), do: Enum.filter(issues(), &(&1["state"] != "closed"))
  defp listed_issues(_), do: issues()

  defp next_number do
    :ets.update_counter(@table, :seq, {2, 1})
  end

  defp bump_seq(number) when is_integer(number) do
    current =
      case :ets.lookup(@table, :seq) do
        [{:seq, n}] -> n
        [] -> 0
      end

    if number > current do
      :ets.insert(@table, {:seq, number})
    end
  end

  defp bump_seq(_), do: :ok

  defp record_post(url, json) do
    prev =
      case :ets.lookup(@table, :posts) do
        [{:posts, list}] -> list
        [] -> []
      end

    :ets.insert(@table, {:posts, [{url, json} | prev]})
  end

  defp issue_from_create(n, json) do
    title = json_get(json, :title) || "Untitled"
    body = json_get(json, :body) || ""
    labels = json_get(json, :labels) || []

    %{
      "number" => n,
      "node_id" => "I_dispatch_#{n}",
      "title" => title,
      "body" => body,
      "labels" => encode_labels(labels),
      "assignee" => %{"login" => "demo"},
      "user" => %{"login" => "svarm"},
      "created_at" => "2026-01-01T00:00:00Z",
      "repository_url" => "https://api.github.com/repos/acme/widgets",
      "state" => "open"
    }
  end

  defp apply_patch(current, json) do
    current
    |> maybe_put_body(json)
    |> maybe_put_labels(json)
    |> maybe_put_state(json)
  end

  defp maybe_put_body(current, json) do
    case json_get(json, :body) do
      nil -> current
      body -> Map.put(current, "body", body)
    end
  end

  defp maybe_put_labels(current, json) do
    case json_get(json, :labels) do
      nil -> current
      labels -> Map.put(current, "labels", encode_labels(labels))
    end
  end

  defp maybe_put_state(current, json) do
    case json_get(json, :state) do
      nil -> current
      state -> Map.put(current, "state", state)
    end
  end

  defp encode_labels(labels) when is_list(labels) do
    Enum.map(labels, fn
      label when is_binary(label) -> %{"name" => label}
      %{"name" => _} = label -> label
      other -> %{"name" => to_string(other)}
    end)
  end

  defp encode_labels(_), do: []

  defp json_get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
