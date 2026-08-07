defmodule SvarmWeb.DevDemoControllerTest do
  use SvarmWeb.ConnCase, async: false

  alias Svarm.{KanbanBridge, Orchestrator, Settings}

  setup do
    KanbanBridge.delete_all_tasks()
    Settings.Store.delete("tracker")
    Application.delete_env(:svarm, :approval_overlay)

    # Demo.seed leaves :orchestrator_poll_interval_ms / :max_concurrent set;
    # restore so later tests do not inherit a 2s poll.
    prev_poll = Application.get_env(:svarm, :orchestrator_poll_interval_ms)
    prev_max = Application.get_env(:svarm, :orchestrator_max_concurrent)

    on_exit(fn ->
      Settings.Store.delete("tracker")
      Application.delete_env(:svarm, :approval_overlay)
      restore_env(:orchestrator_poll_interval_ms, prev_poll)
      restore_env(:orchestrator_max_concurrent, prev_max)

      if Process.whereis(Orchestrator) do
        _ = Orchestrator.reload_config()
      end
    end)

    :ok
  end

  test "POST /dev/demo/seed redirects to board with tasks", %{conn: conn} do
    conn = post(conn, ~p"/dev/demo/seed?goal=test+goal")

    assert redirected_to(conn) == ~p"/board"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "queued"
    assert Enum.any?(KanbanBridge.list_tasks([]), &String.contains?(&1.title, "Demo:"))
  end

  test "POST seed refuses GitHub tracker with error flash", %{conn: conn} do
    assert {:ok, _} =
             Settings.put_tracker(%{
               "kind" => "github",
               "owner" => "acme",
               "repo" => "widgets",
               "api_key" => "ghp_test",
               "auth" => "token"
             })

    KanbanBridge.create_task(%{
      title: "keep me",
      status: "todo",
      assignee: "demo_research"
    })

    conn = post(conn, ~p"/dev/demo/seed")

    assert redirected_to(conn) == ~p"/board"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "GitHub"
    assert [%{title: "keep me"}] = KanbanBridge.list_tasks([])
  end

  test "POST seed refuses non-demo assignee with error flash", %{conn: conn} do
    KanbanBridge.create_task(%{
      title: "real work",
      status: "todo",
      assignee: "default"
    })

    conn = post(conn, ~p"/dev/demo/seed")

    assert redirected_to(conn) == ~p"/board"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "non-demo"
    assert [%{title: "real work"}] = KanbanBridge.list_tasks([])
  end

  defp restore_env(key, nil), do: Application.delete_env(:svarm, key)
  defp restore_env(key, val), do: Application.put_env(:svarm, key, val)
end
