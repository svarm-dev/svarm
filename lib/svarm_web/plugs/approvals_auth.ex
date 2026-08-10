defmodule SvarmWeb.Plugs.ApprovalsAuth do
  @moduledoc """
  Gates `/approvals` and `/setup` — agent runs are high trust.

  - With `config :svarm, approvals_auth: %{username: ..., password: ...}` → HTTP Basic Auth
    (set via `APPROVALS_USER` / `APPROVALS_PASSWORD` env in Docker/prod).
  - Else only when `config :svarm, dev_routes: true` (local dev).
  - Otherwise 404 with setup hints (not a silent empty page).

  Shared helpers are also used by the board LiveView to gate high-trust
  mutations (approve / reject / complete_review):

  - Credentials configured → requires a **fresh** session stamp from Basic Auth
    (`session["board_auth_at"]` unix seconds, set by `BoardAuthCapture`).
    Stamp is sticky for `board_auth_ttl_seconds/0` (default 8h) so normal sessions
    are not re-challenged on every click; expired stamps fail closed until re-auth.
  - Credentials **missing** + `dev_routes` → open (local Mix / intentional demo).
  - Credentials **missing** without `dev_routes` → **fail closed** (production-safe default).
  """
  import Plug.Conn

  # Workday-scale default: operators are not re-prompted mid-session; cookie theft
  # / shared browser risk is bounded. Override via config or BOARD_AUTH_TTL_SECONDS.
  @default_board_auth_ttl_seconds 8 * 60 * 60

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

  @doc """
  True when high-trust board mutations may proceed without Basic Auth credentials.

  Local Mix sets `dev_routes: true`. Production/Docker leave it unset/false so
  missing `APPROVALS_*` fails closed rather than allowing open approve/reject.
  """
  def open_board_mutations_without_auth? do
    Application.get_env(:svarm, :dev_routes, false) == true
  end

  @doc """
  How long a successful Basic Auth proof authorizes board mutations (seconds).

  Default: 8 hours. Config: `:board_auth_ttl_seconds`. Runtime env:
  `BOARD_AUTH_TTL_SECONDS` (positive integer).
  """
  def board_auth_ttl_seconds do
    case Application.get_env(:svarm, :board_auth_ttl_seconds, @default_board_auth_ttl_seconds) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_board_auth_ttl_seconds
    end
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
  Unix second stamp from the session, or `nil` when missing/invalid.

  Only `board_auth_at` (integer) counts. Legacy boolean `board_auth_ok` is
  ignored so upgrades force a fresh Basic Auth proof under TTL rules.
  """
  def session_board_auth_at(session) when is_map(session) do
    case session["board_auth_at"] do
      at when is_integer(at) -> at
      _ -> nil
    end
  end

  def session_board_auth_at(_), do: nil

  @doc """
  Whether `board_auth_at` (unix seconds) is still within `board_auth_ttl_seconds/0`.

  Rejects missing stamps, non-integers, and future stamps (clock skew abuse).
  """
  def board_auth_at_fresh?(at) when is_integer(at) do
    now = System.system_time(:second)
    age = now - at
    age >= 0 and age <= board_auth_ttl_seconds()
  end

  def board_auth_at_fresh?(_), do: false

  @doc """
  Whether a LiveView may perform high-trust board mutations.

  - Credentials configured → requires fresh `session["board_auth_at"]`
    (set by `BoardAuthCapture` when a request had valid Basic Auth; sticky
    until TTL expires).
  - Credentials **not** configured + `dev_routes` → open (local/dev).
  - Credentials **not** configured without `dev_routes` → denied (prod fail-closed).
  """
  def board_mutation_authorized?(session) when is_map(session) do
    cond do
      credentials_configured?() ->
        board_auth_at_fresh?(session_board_auth_at(session))

      open_board_mutations_without_auth?() ->
        true

      true ->
        false
    end
  end

  def board_mutation_authorized?(_) do
    not credentials_configured?() and open_board_mutations_without_auth?()
  end

  @doc """
  Re-check board mutation policy from LiveView assigns + current config.

  Pass the mount-time `board_auth_at` stamp (integer or nil). Freshness is
  evaluated with wall clock on **every** call so a long-lived LiveView socket
  cannot keep mutating after TTL expiry.
  """
  def authorize_board_mutation?(board_auth_at) do
    cond do
      credentials_configured?() ->
        board_auth_at_fresh?(board_auth_at)

      open_board_mutations_without_auth?() ->
        true

      true ->
        false
    end
  end
end
