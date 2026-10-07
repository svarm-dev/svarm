defmodule Svarm.Tracker.Kaneo do
  @moduledoc """
  Kaneo (self-hosted board) tracker adapter.

  Implements `Svarm.Tracker` against the Kaneo REST API:

    * board       `GET  /api/task/tasks/{projectId}`
    * get task    `GET  /api/task/{id}`
    * create task `POST /api/task/{projectId}`
    * move column `PUT  /api/task/status/{id}`

  Authentication is the `x-api-key` header. A task's Svärm status is the
  slug of the Kaneo column it sits in, so `tracker.active_states` and
  `tracker.terminal_states` name board columns (for example `todo`,
  `in_progress`, `done`). Eligible tasks are exactly the tasks in the
  configured active columns.

  Kaneo has no CI/PR signals, so `capabilities/0` returns `[]`. Retry
  attempts stay tracker-durable in `Svarm.Coordination`; `depends_on`,
  follow-up text, claims, and run summaries are no-ops because the
  orchestrator's dispatch gating already lives in the local coordination
  store / board.
  """
  @behaviour Svarm.Tracker

  alias Svarm.Coordination
  alias Svarm.Tracker.Kaneo.{Eligibility, Normalize}

  require Logger

  @default_active_states ["todo", "in_progress"]

  @impl true
  def capabilities, do: []

  @impl true
  def list_eligible(config) do
    with {:ok, board} <- fetch_board(config) do
      issues =
        board
        |> Normalize.from_board(config)
        |> Normalize.attach_attempts()
        |> Enum.filter(&Eligibility.eligible?(&1, config))

      {:ok, issues}
    end
  end

  @impl true
  def get_issue(config, id) when is_binary(id) do
    case req(config).get(url(config, "/task/#{id}"), headers: headers(config)) do
      {:ok, %{status: 200, body: task}} when is_map(task) ->
        {:ok, task |> Normalize.from_task(config) |> Normalize.attach_attempts()}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      other ->
        {:error, http_error(other)}
    end
  end

  @impl true
  def get_issues(_config, []), do: {:ok, %{}}

  def get_issues(config, ids) when is_list(ids) do
    case ids |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] -> {:ok, %{}}
      [one] -> {:ok, %{one => get_issue(config, one)}}
      many -> get_issues_from_board(config, many)
    end
  end

  @impl true
  def list_issues(config, filters \\ []) do
    {include_body, filters} = Keyword.pop(filters, :include_body, true)

    with {:ok, board} <- fetch_board(config) do
      issues =
        board
        |> Normalize.from_board(config)
        |> Normalize.attach_attempts()
        |> filter_issues(filters)
        |> maybe_strip_bodies(include_body)

      {:ok, issues}
    end
  end

  @impl true
  def create_issue(config, attrs) do
    project = Map.fetch!(config, :project)

    case req(config).post(url(config, "/task/#{project}"),
           json: create_body(attrs, config),
           headers: headers(config)
         ) do
      {:ok, %{status: status, body: task}} when status in [200, 201] and is_map(task) ->
        {:ok, Normalize.from_task(task, config)}

      other ->
        {:error, http_error(other)}
    end
  end

  @impl true
  def update_status(config, id, status) when is_binary(id) and is_binary(status) do
    case req(config).put(url(config, "/task/status/#{id}"),
           json: %{status: status},
           headers: headers(config)
         ) do
      {:ok, %{status: status_code}} when status_code in [200, 204] -> :ok
      other -> {:error, http_error(other)}
    end
  end

  @impl true
  def update_attempts(_config, id, attempts)
      when is_binary(id) and is_integer(attempts) and attempts >= 0 do
    # Fail closed: a swallowed upsert would re-fetch attempts: 0 and retry forever.
    {:ok, _row} = Coordination.upsert(id, %{attempts: attempts})
    :ok
  end

  @impl true
  def update_depends_on(_config, _id, _depends_on), do: :ok

  @impl true
  def update_follow_up(_config, _id, _text), do: :ok

  @impl true
  def claim(_config, _id), do: :ok

  @impl true
  def delete_all(_config), do: :ok

  @impl true
  def post_run_summary(_config, _id, _summary), do: :ok

  # -- private --

  defp get_issues_from_board(config, ids) do
    with {:ok, board} <- fetch_board(config) do
      snapshot =
        board
        |> Normalize.from_board(config)
        |> Normalize.attach_attempts()
        |> Enum.reduce(%{}, fn issue, acc ->
          acc
          |> put_snapshot(issue.id, issue)
          |> put_snapshot(issue.source_id, issue)
        end)

      {:ok, Map.new(ids, fn id -> {id, resolve_snapshot(config, id, snapshot)} end)}
    end
  end

  defp resolve_snapshot(config, id, snapshot) do
    case Map.fetch(snapshot, id) do
      {:ok, issue} -> {:ok, issue}
      :error -> get_issue(config, id)
    end
  end

  defp put_snapshot(map, key, issue) when is_binary(key) and key != "",
    do: Map.put(map, key, issue)

  defp put_snapshot(map, _key, _issue), do: map

  defp fetch_board(config) do
    project = Map.fetch!(config, :project)

    case req(config).get(url(config, "/task/tasks/#{project}"), headers: headers(config)) do
      {:ok, %{status: 200, body: board}} when is_map(board) -> {:ok, board}
      other -> {:error, http_error(other)}
    end
  end

  defp filter_issues(issues, []), do: issues

  defp filter_issues(issues, filters) do
    Enum.filter(issues, fn issue ->
      Enum.all?(filters, fn
        {:status, status} -> issue.status == status
        {:assignee, assignee} -> issue.assignee == assignee
        _ -> true
      end)
    end)
  end

  defp maybe_strip_bodies(issues, true), do: issues
  defp maybe_strip_bodies(issues, false), do: Enum.map(issues, &%{&1 | body: nil, raw: nil})

  defp create_body(attrs, config) do
    attrs = attrs || %{}

    %{
      title: Map.get(attrs, :title) || "Untitled",
      description: Map.get(attrs, :body) || "",
      priority: Normalize.to_api_priority(Map.get(attrs, :priority)),
      status: Map.get(attrs, :status) || first_active_state(config)
    }
  end

  defp first_active_state(config) do
    case Map.get(config, :active_states, @default_active_states) do
      [first | _] when is_binary(first) and first != "" -> first
      _ -> "todo"
    end
  end

  defp url(config, path) do
    base = config |> Map.fetch!(:base_url) |> String.trim_trailing("/")
    base <> "/api" <> path
  end

  defp req(config) when is_map(config) do
    Map.get(config, :req) || Application.get_env(:svarm, :kaneo_req, Req)
  end

  defp headers(config) when is_map(config) do
    case Map.get(config, :api_key) do
      key when is_binary(key) and key != "" -> ["x-api-key": key]
      _ -> []
    end
  end

  defp http_error({:ok, %{status: 401}}), do: error(:auth_failure, "bad Kaneo API key")
  defp http_error({:ok, %{status: 403}}), do: error(:forbidden, "Kaneo access denied")
  defp http_error({:ok, %{status: 404}}), do: error(:not_found, "Kaneo resource not found")

  defp http_error({:ok, %{status: 429} = resp}),
    do: error(:rate_limit, "rate limited", retry_after(Map.get(resp, :headers, %{})))

  defp http_error({:ok, %{status: code}}) when is_integer(code),
    do: error(:server_error, "Kaneo API error #{code}")

  defp http_error({:error, reason}) do
    Logger.error("kaneo tracker: #{inspect(reason)}")
    error(:network_error, "cannot reach Kaneo API")
  end

  defp http_error(_other), do: error(:server_error, "Kaneo API error")

  defp retry_after(headers) when is_map(headers) do
    value =
      get_in(headers, ["retry-after", Access.at(0)]) ||
        get_in(headers, ["Retry-After", Access.at(0)]) ||
        Map.get(headers, "retry-after") ||
        Map.get(headers, "Retry-After")

    cond do
      is_binary(value) -> String.to_integer(value)
      is_list(value) and value != [] -> value |> hd() |> to_string() |> String.to_integer()
      true -> 60
    end
  end

  defp retry_after(_), do: 60

  defp error(type, message, retry_after \\ nil) do
    %{type: type, message: message, retry_after: retry_after}
  end
end
