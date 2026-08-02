defmodule SvarmWeb.Plugs.ApprovalsAuthTest do
  use SvarmWeb.ConnCase, async: false

  setup do
    prev_auth = Application.get_env(:svarm, :approvals_auth)
    prev_dev = Application.get_env(:svarm, :dev_routes)

    on_exit(fn ->
      if prev_auth == nil,
        do: Application.delete_env(:svarm, :approvals_auth),
        else: Application.put_env(:svarm, :approvals_auth, prev_auth)

      Application.put_env(:svarm, :dev_routes, prev_dev)
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

  test "credentials_configured? and board_mutation_authorized?" do
    Application.delete_env(:svarm, :approvals_auth)
    refute SvarmWeb.Plugs.ApprovalsAuth.credentials_configured?()
    assert SvarmWeb.Plugs.ApprovalsAuth.board_mutation_authorized?(%{})
    assert SvarmWeb.Plugs.ApprovalsAuth.authorize_board_mutation?(false)

    Application.put_env(:svarm, :approvals_auth, %{username: "a", password: "b"})
    assert SvarmWeb.Plugs.ApprovalsAuth.credentials_configured?()
    refute SvarmWeb.Plugs.ApprovalsAuth.board_mutation_authorized?(%{})
    assert SvarmWeb.Plugs.ApprovalsAuth.board_mutation_authorized?(%{"board_auth_ok" => true})
    refute SvarmWeb.Plugs.ApprovalsAuth.authorize_board_mutation?(false)
    assert SvarmWeb.Plugs.ApprovalsAuth.authorize_board_mutation?(true)
  end
end
