defmodule Svarm.Test.KaneoStubServer do
  @moduledoc false
  # Minimal in-process Kaneo HTTP API for adapter tests (no live Kaneo).
  #
  # Implements the endpoints the adapter calls:
  #   GET  /api/task/tasks/{projectId}
  #   POST /api/task/{projectId}
  #   GET  /api/task/{id}
  #   PUT  /api/task/status/{id}
  #
  # State lives in an Agent so a status move is visible on the next board read.
  @behaviour Plug

  alias Plug.Conn

  def start do
    {:ok, agent} = Agent.start_link(fn -> %{tasks: %{}, requests: []} end)
    {:ok, pid} = Bandit.start_link(plug: {__MODULE__, [agent: agent]}, port: 0)
    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    %{agent: agent, pid: pid, base_url: "http://127.0.0.1:#{port}"}
  end

  def stop(%{agent: agent, pid: pid}) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  catch
    :exit, _ -> :ok
  end

  def seed(%{agent: agent}, tasks) when is_list(tasks) do
    Agent.update(agent, fn state ->
      %{state | tasks: Map.new(tasks, fn task -> {task["id"], task} end)}
    end)
  end

  def requests(%{agent: agent}) do
    Agent.get(agent, &Enum.reverse(&1.requests))
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    agent = Keyword.fetch!(opts, :agent)
    body = decode(read_body(conn))
    record(agent, conn, body)
    dispatch(conn, agent, body)
  end

  defp read_body(conn) do
    case Conn.read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  defp record(agent, conn, body) do
    entry = %{
      method: conn.method,
      path: conn.request_path,
      params: URI.decode_query(conn.query_string),
      headers: conn.req_headers,
      body: body
    }

    Agent.update(agent, fn state -> %{state | requests: [entry | state.requests]} end)
  end

  defp decode(""), do: nil

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      _ -> body
    end
  end

  defp dispatch(%{method: "GET", request_path: "/api/column/" <> project_id} = conn, agent, _) do
    send_json(conn, 200, columns(agent, project_id))
  end

  defp dispatch(%{method: "GET", request_path: "/api/task/tasks/" <> project_id} = conn, agent, _) do
    send_json(conn, 200, board(agent, project_id, URI.decode_query(conn.query_string)))
  end

  defp dispatch(%{method: "POST", request_path: "/api/task/" <> project_id} = conn, agent, body) do
    create(conn, agent, project_id, body || %{})
  end

  defp dispatch(%{method: "PUT", request_path: "/api/task/status/" <> id} = conn, agent, body) do
    update_status(conn, agent, id, body || %{})
  end

  defp dispatch(%{method: "GET", request_path: "/api/task/" <> id} = conn, agent, _) do
    case get_task(agent, id) do
      nil -> send_json(conn, 404, %{"message" => "Task not found"})
      task -> send_json(conn, 200, task)
    end
  end

  defp dispatch(conn, _agent, _body) do
    send_json(conn, 404, %{"message" => "Not found"})
  end

  # Stock Kaneo columns. `pending-approval` is intentionally absent so a
  # default hold fails closed until the operator adds that column.
  @stock_columns ["to-do", "in-progress", "in-review", "done"]

  defp columns(_agent, _project_id) do
    Enum.map(@stock_columns, fn slug ->
      %{"id" => slug, "slug" => slug, "name" => slug, "isFinal" => slug == "done"}
    end)
  end

  defp board(agent, project_id, params) do
    tasks =
      agent
      |> Agent.get(& &1.tasks)
      |> Map.values()
      |> Enum.filter(&(&1["projectId"] == project_id))
      |> Enum.sort_by(& &1["id"])

    page = positive_int(params["page"], 1)
    limit = positive_int(params["limit"], 50)
    total = length(tasks)
    total_pages = max(1, div(total + limit - 1, limit))
    page_tasks = Enum.slice(tasks, (page - 1) * limit, limit)

    columns =
      page_tasks
      |> Enum.group_by(& &1["status"])
      |> Enum.sort_by(fn {status, _tasks} -> status end)
      |> Enum.map(fn {status, column_tasks} ->
        %{
          "id" => status,
          "slug" => status,
          "name" => status,
          "isFinal" => status == "done",
          "tasks" => column_tasks
        }
      end)

    %{
      "data" => %{
        "id" => project_id,
        "workspaceId" => "ws_1",
        "columns" => columns,
        "archivedTasks" => [],
        "plannedTasks" => []
      },
      "pagination" => %{
        "total" => total,
        "page" => page,
        "pageSize" => limit,
        "totalPages" => total_pages
      }
    }
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp positive_int(_, default), do: default

  defp create(conn, agent, project_id, body) do
    id = "task_" <> Integer.to_string(:erlang.unique_integer([:positive]))

    task = %{
      "id" => id,
      "projectId" => project_id,
      "title" => body["title"],
      "description" => body["description"],
      "status" => body["status"] || "todo",
      "priority" => body["priority"] || "no-priority",
      "userId" => nil,
      "assigneeName" => nil,
      "number" => 1,
      "createdAt" => "2026-01-01T00:00:00.000Z",
      "labels" => []
    }

    Agent.update(agent, fn state -> %{state | tasks: Map.put(state.tasks, id, task)} end)
    send_json(conn, 200, task)
  end

  defp update_status(conn, agent, id, body) do
    case get_task(agent, id) do
      nil ->
        send_json(conn, 404, %{"message" => "Task not found"})

      task ->
        updated = Map.put(task, "status", body["status"] || task["status"])
        Agent.update(agent, fn state -> %{state | tasks: Map.put(state.tasks, id, updated)} end)
        send_json(conn, 200, updated)
    end
  end

  defp get_task(agent, id), do: Agent.get(agent, &Map.get(&1.tasks, id))

  defp send_json(conn, status, body) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, Jason.encode!(body))
  end
end
