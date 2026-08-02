defmodule SvarmWeb.Plugs.ApprovalsAuth do
  @moduledoc """
  Gates `/approvals` and `/setup` — agent runs are high trust.

  - With `config :svarm, approvals_auth: %{username: ..., password: ...}` → HTTP Basic Auth
    (set via `APPROVALS_USER` / `APPROVALS_PASSWORD` env in Docker/prod).
  - Else only when `config :svarm, dev_routes: true` (local dev).
  - Otherwise 404 with setup hints (not a silent empty page).

  Shared helpers are also used by the board LiveView to gate high-trust
  mutations (approve / reject / complete_review) when credentials are configured.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      credentials_configured?() and authorized_header?(conn) ->
        conn

      credentials_configured?() ->
        conn
        |> put_resp_header("www-authenticate", ~s|Basic realm="Svärm approvals"|)
        |> send_resp(401, "Unauthorized")
        |> halt()

      Application.get_env(:svarm, :dev_routes) ->
        conn

      true ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, """
        Approvals UI is disabled.

        Set APPROVALS_USER and APPROVALS_PASSWORD in .env (Docker/prod Basic Auth),
        or use dev_routes in local Mix, or set approval.mode: off in WORKFLOW.md for a
        throwaway smoke box (not for real repos).

        See GETTING-STARTED.md.
        """)
        |> halt()
    end
  end

  @doc "True when `approvals_auth` has non-empty username and password."
  def credentials_configured? do
    match?(
      %{username: u, password: p} when is_binary(u) and u != "" and is_binary(p) and p != "",
      Application.get_env(:svarm, :approvals_auth)
    )
  end

  @doc "True when the request carries valid Basic Auth for configured credentials."
  def authorized_header?(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, userpass} <- Base.decode64(encoded),
         %{username: u, password: p} <- Application.get_env(:svarm, :approvals_auth),
         expected when is_binary(expected) <- "#{u}:#{p}" do
      # Constant-time compare; lengths must match or secure_compare raises
      byte_size(userpass) == byte_size(expected) and
        Plug.Crypto.secure_compare(userpass, expected)
    else
      _ -> false
    end
  end

  @doc """
  Whether a LiveView may perform high-trust board mutations.

  - Credentials **not** configured → open (dev / firewalled operator model).
  - Credentials configured → requires `session["board_auth_ok"] == true`
    (set by `BoardAuthCapture` when a request had valid Basic Auth; sticky).
  """
  def board_mutation_authorized?(session) when is_map(session) do
    if credentials_configured?() do
      session["board_auth_ok"] == true
    else
      true
    end
  end

  def board_mutation_authorized?(_), do: not credentials_configured?()

  @doc """
  Re-check board mutation policy from LiveView assigns + current config.

  Fail closed if credentials are configured and the mount-time proof is missing.
  """
  def authorize_board_mutation?(board_auth_ok) when is_boolean(board_auth_ok) do
    if credentials_configured?() do
      board_auth_ok
    else
      true
    end
  end
end
