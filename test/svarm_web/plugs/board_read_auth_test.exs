defmodule SvarmWeb.Plugs.BoardReadAuthTest do
  use SvarmWeb.LiveCase, async: false

  alias SvarmWeb.Live.BoardReadHook
  alias SvarmWeb.Plugs.ApprovalsAuth

  setup do
    prev_auth = Application.get_env(:svarm, :approvals_auth)
    prev_dev = Application.get_env(:svarm, :dev_routes)
    prev_read = Application.get_env(:svarm, :board_read_auth)

    on_exit(fn ->
      if prev_auth == nil,
        do: Application.delete_env(:svarm, :approvals_auth),
        else: Application.put_env(:svarm, :approvals_auth, prev_auth)

      Application.put_env(:svarm, :dev_routes, prev_dev)

      if prev_read == nil,
        do: Application.delete_env(:svarm, :board_read_auth),
        else: Application.put_env(:svarm, :board_read_auth, prev_read)
    end)

    :ok
  end

  test "flag off leaves /board and /dashboard open", %{conn: conn} do
    Application.put_env(:svarm, :board_read_auth, false)
    Application.delete_env(:svarm, :approvals_auth)

    assert html_response(get(conn, ~p"/board"), 200)
    assert html_response(get(conn, ~p"/dashboard"), 200)
    {:ok, _view, _html} = live(conn, ~p"/board")
  end

  test "flag on + credentials challenges GET /board and /dashboard", %{conn: conn} do
    Application.put_env(:svarm, :board_read_auth, true)
    Application.put_env(:svarm, :dev_routes, false)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    board = get(conn, ~p"/board")
    assert response(board, 401) =~ "Unauthorized"
    assert get_resp_header(board, "www-authenticate") == [~s|Basic realm="Svärm approvals"|]

    dash = get(conn, ~p"/dashboard")
    assert response(dash, 401) =~ "Unauthorized"
    assert get_resp_header(dash, "www-authenticate") == [~s|Basic realm="Svärm approvals"|]
  end

  test "flag on + valid Basic Auth mounts board and dashboard", %{conn: conn} do
    Application.put_env(:svarm, :board_read_auth, true)
    Application.put_env(:svarm, :dev_routes, false)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    creds = Base.encode64("op:secret")

    conn = put_req_header(conn, "authorization", "Basic #{creds}")
    assert html_response(get(conn, ~p"/board"), 200)
    assert html_response(get(conn, ~p"/dashboard"), 200)
    {:ok, _view, html} = live(conn, ~p"/board")
    assert html =~ "phx-"
  end

  test "flag on + sticky board_auth_at allows a later GET without Authorization", %{conn: conn} do
    Application.put_env(:svarm, :board_read_auth, true)
    Application.put_env(:svarm, :dev_routes, false)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    creds = Base.encode64("op:secret")

    conn =
      conn
      |> put_req_header("authorization", "Basic #{creds}")
      |> get(~p"/board")

    assert html_response(conn, 200)
    assert is_integer(get_session(conn, "board_auth_at"))

    recycled = recycle(conn)
    assert html_response(get(recycled, ~p"/board"), 200)
    {:ok, _view, _html} = live(recycled, ~p"/dashboard")
  end

  test "flag on without credentials fails closed on board/dashboard", %{conn: conn} do
    Application.put_env(:svarm, :board_read_auth, true)
    Application.put_env(:svarm, :dev_routes, false)
    Application.delete_env(:svarm, :approvals_auth)

    board = get(conn, ~p"/board")
    assert response(board, 404) =~ "BOARD_READ_AUTH"
    assert response(board, 404) =~ "APPROVALS_USER"
    refute get_resp_header(board, "www-authenticate") == [~s|Basic realm="Svärm approvals"|]

    dash = get(conn, ~p"/dashboard")
    assert response(dash, 404) =~ "APPROVALS_PASSWORD"
  end

  test "GET /health stays open when read auth is on", %{conn: conn} do
    Application.put_env(:svarm, :board_read_auth, true)
    Application.put_env(:svarm, :dev_routes, false)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    conn = get(conn, ~p"/health")
    assert response(conn, 200) == "ok"
  end

  test "GET / stays open when read auth is on", %{conn: conn} do
    Application.put_env(:svarm, :board_read_auth, true)
    Application.put_env(:svarm, :dev_routes, false)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "This instance"
  end

  test "on_mount halts without a fresh session stamp when the flag is on" do
    Application.put_env(:svarm, :board_read_auth, true)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    socket = %Phoenix.LiveView.Socket{endpoint: SvarmWeb.Endpoint, router: SvarmWeb.Router}

    assert {:halt, halted} = BoardReadHook.on_mount(:default, %{}, %{}, socket)
    assert match?({:redirect, %{to: "/"}}, halted.redirected)

    now = System.system_time(:second)
    assert {:cont, _} = BoardReadHook.on_mount(:default, %{}, %{"board_auth_at" => now}, socket)
  end

  test "on_mount continues when the flag is off" do
    Application.put_env(:svarm, :board_read_auth, false)
    socket = %Phoenix.LiveView.Socket{endpoint: SvarmWeb.Endpoint, router: SvarmWeb.Router}
    assert {:cont, _} = BoardReadHook.on_mount(:default, %{}, %{}, socket)
    assert ApprovalsAuth.board_read_authorized?(%{})
  end
end
