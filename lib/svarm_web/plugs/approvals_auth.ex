defmodule SvarmWeb.Plugs.ApprovalsAuth do
  @moduledoc """
  Gates `/approvals` — agent runs are high trust.

  - With `config :svarm, approvals_auth: %{username: ..., password: ...}` → HTTP Basic Auth.
  - Else only when `config :svarm, dev_routes: true` (local dev).
  - Otherwise 404 (not advertised in production).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      credentials_configured?() and basic_auth_ok?(conn) ->
        conn

      credentials_configured?() ->
        conn
        |> put_resp_header("www-authenticate", ~s|Basic realm="Svärm approvals"|)
        |> send_resp(401, "Unauthorized")
        |> halt()

      Application.get_env(:svarm, :dev_routes) ->
        conn

      true ->
        conn |> send_resp(404, "Not found") |> halt()
    end
  end

  defp credentials_configured? do
    match?(
      %{username: u, password: p} when is_binary(u) and u != "" and is_binary(p) and p != "",
      Application.get_env(:svarm, :approvals_auth)
    )
  end

  defp basic_auth_ok?(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, userpass} <- Base.decode64(encoded),
         %{username: u, password: p} <- Application.get_env(:svarm, :approvals_auth) do
      userpass == "#{u}:#{p}"
    else
      _ -> false
    end
  end
end
