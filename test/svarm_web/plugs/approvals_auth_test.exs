defmodule SvarmWeb.Plugs.ApprovalsAuthTest do
  use SvarmWeb.ConnCase, async: false

  alias SvarmWeb.Plugs.ApprovalsAuth

  setup do
    prev_auth = Application.get_env(:svarm, :approvals_auth)
    prev_dev = Application.get_env(:svarm, :dev_routes)
    prev_ttl = Application.get_env(:svarm, :board_auth_ttl_seconds)

    on_exit(fn ->
      if prev_auth == nil,
        do: Application.delete_env(:svarm, :approvals_auth),
        else: Application.put_env(:svarm, :approvals_auth, prev_auth)

      Application.put_env(:svarm, :dev_routes, prev_dev)

      if prev_ttl == nil,
        do: Application.delete_env(:svarm, :board_auth_ttl_seconds),
        else: Application.put_env(:svarm, :board_auth_ttl_seconds, prev_ttl)
    end)

    :ok
  end

  test "dev_routes allows unauthenticated access", %{conn: conn} do
    Application.put_env(:svarm, :dev_routes, true)
    Application.delete_env(:svarm, :approvals_auth)

    conn = get(conn, ~p"/approvals")
    assert html_response(conn, 200) =~ "Approvals"
  end

  test "basic auth accepts configured credentials", %{conn: conn} do
    Application.put_env(:svarm, :dev_routes, false)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    creds = Base.encode64("op:secret")

    conn =
      conn
      |> put_req_header("authorization", "Basic #{creds}")
      |> get(~p"/approvals")

    assert html_response(conn, 200) =~ "Approvals"
  end

  test "basic auth rejects wrong password", %{conn: conn} do
    Application.put_env(:svarm, :dev_routes, false)
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    creds = Base.encode64("op:wrong")

    conn =
      conn
      |> put_req_header("authorization", "Basic #{creds}")
      |> get(~p"/approvals")

    assert response(conn, 401) =~ "Unauthorized"
  end

  test "without auth or dev_routes returns setup hint", %{conn: conn} do
    Application.put_env(:svarm, :dev_routes, false)
    Application.delete_env(:svarm, :approvals_auth)

    conn = get(conn, ~p"/approvals")
    body = response(conn, 404)
    assert body =~ "APPROVALS_USER"
    assert body =~ "APPROVALS_PASSWORD"
  end

  test "credentials_configured? and board_mutation_authorized? with fresh stamp" do
    Application.delete_env(:svarm, :approvals_auth)
    Application.put_env(:svarm, :dev_routes, true)
    refute ApprovalsAuth.credentials_configured?()
    assert ApprovalsAuth.open_board_mutations_without_auth?()
    assert ApprovalsAuth.board_mutation_authorized?(%{})
    assert ApprovalsAuth.authorize_board_mutation?(nil)

    Application.put_env(:svarm, :approvals_auth, %{username: "a", password: "b"})
    assert ApprovalsAuth.credentials_configured?()
    refute ApprovalsAuth.board_mutation_authorized?(%{})
    refute ApprovalsAuth.board_mutation_authorized?(%{"board_auth_ok" => true})

    now = System.system_time(:second)
    assert ApprovalsAuth.board_mutation_authorized?(%{"board_auth_at" => now})
    refute ApprovalsAuth.authorize_board_mutation?(nil)
    assert ApprovalsAuth.authorize_board_mutation?(now)
  end

  test "expired board_auth_at fails closed when credentials configured" do
    Application.put_env(:svarm, :dev_routes, false)
    Application.put_env(:svarm, :approvals_auth, %{username: "a", password: "b"})
    Application.put_env(:svarm, :board_auth_ttl_seconds, 60)

    expired = System.system_time(:second) - 120
    refute ApprovalsAuth.board_auth_at_fresh?(expired)
    refute ApprovalsAuth.board_mutation_authorized?(%{"board_auth_at" => expired})
    refute ApprovalsAuth.authorize_board_mutation?(expired)

    fresh = System.system_time(:second) - 30
    assert ApprovalsAuth.board_auth_at_fresh?(fresh)
    assert ApprovalsAuth.board_mutation_authorized?(%{"board_auth_at" => fresh})
    assert ApprovalsAuth.authorize_board_mutation?(fresh)
  end

  test "missing board_auth_at fails when credentials configured" do
    Application.put_env(:svarm, :approvals_auth, %{username: "a", password: "b"})
    refute ApprovalsAuth.session_board_auth_at(%{})
    refute ApprovalsAuth.board_auth_at_fresh?(nil)
    refute ApprovalsAuth.board_mutation_authorized?(%{})
    refute ApprovalsAuth.authorize_board_mutation?(nil)
  end

  test "future board_auth_at is rejected" do
    Application.put_env(:svarm, :approvals_auth, %{username: "a", password: "b"})
    future = System.system_time(:second) + 3600
    refute ApprovalsAuth.board_auth_at_fresh?(future)
    refute ApprovalsAuth.authorize_board_mutation?(future)
  end

  test "board_auth_ttl_seconds defaults and rejects non-positive config" do
    Application.delete_env(:svarm, :board_auth_ttl_seconds)
    assert ApprovalsAuth.board_auth_ttl_seconds() == 8 * 60 * 60

    Application.put_env(:svarm, :board_auth_ttl_seconds, 0)
    assert ApprovalsAuth.board_auth_ttl_seconds() == 8 * 60 * 60

    Application.put_env(:svarm, :board_auth_ttl_seconds, 120)
    assert ApprovalsAuth.board_auth_ttl_seconds() == 120
  end

  test "prod-like: missing credentials fail closed for board mutations" do
    Application.put_env(:svarm, :dev_routes, false)
    Application.delete_env(:svarm, :approvals_auth)

    refute ApprovalsAuth.credentials_configured?()
    refute ApprovalsAuth.open_board_mutations_without_auth?()
    refute ApprovalsAuth.board_mutation_authorized?(%{})

    refute ApprovalsAuth.board_mutation_authorized?(%{
             "board_auth_at" => System.system_time(:second)
           })

    refute ApprovalsAuth.authorize_board_mutation?(System.system_time(:second))
    refute ApprovalsAuth.authorize_board_mutation?(nil)
  end

  test "dev_routes keeps board mutations open without credentials" do
    Application.put_env(:svarm, :dev_routes, true)
    Application.delete_env(:svarm, :approvals_auth)

    assert ApprovalsAuth.open_board_mutations_without_auth?()
    assert ApprovalsAuth.board_mutation_authorized?(%{})
    assert ApprovalsAuth.authorize_board_mutation?(nil)
  end

  test "BoardAuthCapture stamps board_auth_at on valid Basic Auth", %{conn: conn} do
    Application.put_env(:svarm, :approvals_auth, %{username: "op", password: "secret"})

    creds = Base.encode64("op:secret")
    before = System.system_time(:second)

    conn =
      conn
      |> put_req_header("authorization", "Basic #{creds}")
      |> get(~p"/board")

    assert html_response(conn, 200)
    at = get_session(conn, "board_auth_at")
    assert is_integer(at)
    assert at >= before
    assert at <= System.system_time(:second)
  end
end
