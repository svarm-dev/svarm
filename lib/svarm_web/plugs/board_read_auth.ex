defmodule SvarmWeb.Plugs.BoardReadAuth do
  @moduledoc """
  Opt-in Basic Auth for `/board` and `/dashboard` **reads**.

  Off by default (`:board_read_auth` / `BOARD_READ_AUTH`). When on, reuses
  `APPROVALS_USER` / `APPROVALS_PASSWORD` — no second credential pair.

  HTTP GET is challenged here (`401` + `WWW-Authenticate`). The LiveView
  `/live` websocket skips the router, so `SvarmWeb.Live.BoardReadHook`
  must also run on mount.
  """
  import Plug.Conn

  alias SvarmWeb.Plugs.ApprovalsAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not ApprovalsAuth.board_read_auth_enabled?() ->
        conn

      read_allowed?(conn) ->
        conn

      ApprovalsAuth.credentials_configured?() ->
        conn
        |> put_resp_header("www-authenticate", ~s|Basic realm="Svärm approvals"|)
        |> send_resp(401, "Unauthorized")
        |> halt()

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, """
        Board and dashboard reads are locked (BOARD_READ_AUTH) but APPROVALS_USER /
        APPROVALS_PASSWORD are not set.

        Set those credentials in .env, or turn BOARD_READ_AUTH off.

        See GETTING-STARTED.md and SECURITY.md.
        """)
        |> halt()
    end
  end

  defp read_allowed?(conn) do
    ApprovalsAuth.authorized_header?(conn) or
      ApprovalsAuth.board_read_authorized?(%{
        "board_auth_at" => get_session(conn, "board_auth_at")
      })
  end
end
