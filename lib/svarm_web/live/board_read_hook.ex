defmodule SvarmWeb.Live.BoardReadHook do
  @moduledoc """
  LiveView `on_mount` gate for `/board` and `/dashboard` when read auth is on.

  The `/live` websocket connects on the endpoint and skips router plugs, so
  HTTP `BoardReadAuth` alone is not enough. Session proof is the sticky
  `board_auth_at` stamp (LiveView sockets do not send `Authorization`).
  """
  import Phoenix.LiveView

  alias SvarmWeb.Plugs.ApprovalsAuth

  def on_mount(:default, _params, session, socket) do
    if ApprovalsAuth.board_read_authorized?(session) do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end
end
