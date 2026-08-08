defmodule SvarmWeb.Plugs.BoardAuthCapture do
  @moduledoc """
  Captures Basic Auth proof into the session for board LiveView mutations.

  Does **not** challenge or block the request — board reads stay open when
  `approvals_auth` is configured. High-trust LiveView events re-check
  `session["board_auth_ok"]` via `ApprovalsAuth.board_mutation_authorized?/1`.

  When credentials are configured: valid Authorization **promotes** the session
  flag to true and is never cleared by a later request without a header (sticky
  until the session ends). When credentials are not configured: this plug is a
  no-op; mutation policy is decided by `ApprovalsAuth` (`dev_routes` open vs
  production fail-closed).
  """
  import Plug.Conn

  alias SvarmWeb.Plugs.ApprovalsAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not ApprovalsAuth.credentials_configured?() ->
        # Policy lives in ApprovalsAuth (dev open / prod fail-closed)
        conn

      ApprovalsAuth.authorized_header?(conn) ->
        put_session(conn, "board_auth_ok", true)

      true ->
        # Sticky: keep an earlier successful Basic Auth proof; do not demote
        conn
    end
  end
end
