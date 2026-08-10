defmodule SvarmWeb.Plugs.BoardAuthCapture do
  @moduledoc """
  Captures Basic Auth proof into the session for board LiveView mutations.

  Does **not** challenge or block the request — board reads stay open when
  `approvals_auth` is configured. High-trust LiveView events re-check
  `session["board_auth_at"]` freshness via `ApprovalsAuth.board_mutation_authorized?/1`
  and wall-clock TTL on each mutation.

  When credentials are configured: valid Authorization **promotes** the session
  stamp to the current unix second (refreshing TTL). Follow-up requests without
  a header keep the existing stamp (sticky until `board_auth_ttl_seconds/0`
  elapses). When credentials are not configured: this plug is a no-op; mutation
  policy is decided by `ApprovalsAuth` (`dev_routes` open vs production fail-closed).
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
        # Fresh proof: stamp now (also refreshes TTL on re-challenge)
        put_session(conn, "board_auth_at", System.system_time(:second))

      true ->
        # Sticky: keep an earlier successful Basic Auth stamp; do not demote
        conn
    end
  end
end
