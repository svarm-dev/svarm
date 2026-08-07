import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/svarm start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :svarm, SvarmWeb.Endpoint, server: true
end

config :svarm, SvarmWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :svarm, :console_base_url, System.get_env("SVARM_BASE_URL")

# Approvals Basic Auth (Docker/prod). Local Mix uses dev_routes instead.
approvals_user = System.get_env("APPROVALS_USER")
approvals_pass = System.get_env("APPROVALS_PASSWORD")

if is_binary(approvals_user) and approvals_user != "" and is_binary(approvals_pass) and
     approvals_pass != "" do
  config :svarm, :approvals_auth, %{username: approvals_user, password: approvals_pass}
end

# Demo knobs (prod release keeps these off unless env is set):
#   SVARM_SEED_DEMO=1   → boot-seed mock tasks when board empty (Docker demo)
#   SVARM_DEMO_ROUTES=1 → Seed demo button + POST /dev/demo/seed (not implied by SEED)
seed_demo? = System.get_env("SVARM_SEED_DEMO") in ~w(1 true TRUE yes YES on ON)
demo_routes? = System.get_env("SVARM_DEMO_ROUTES") in ~w(1 true TRUE yes YES on ON)

if demo_routes? do
  config :svarm, :demo_routes, true
end

if seed_demo? do
  config :svarm, :seed_demo_on_boot, true
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :svarm, SvarmWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/svarm_web/router\.ex$"E,
        ~r"lib/svarm_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # Database path for SQLite — defaults to data volume in Docker
  db_path = System.get_env("SVARM_DB_PATH", "/app/data/kanban.db")
  config :svarm, Svarm.Repo, database: db_path

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # LiveView/WebSocket origin checks — never leave production open.
  # Default: PHX_HOST only. Optional PHX_CHECK_ORIGIN is a comma-separated
  # allow-list of hosts or full origins (//host, https://host:port, wildcards).
  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN") do
      nil ->
        ["//#{host}"]

      raw ->
        origins =
          raw
          |> String.split(",", trim: true)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn origin ->
            if String.starts_with?(origin, ["//", "http://", "https://"]) do
              origin
            else
              "//#{origin}"
            end
          end)

        case origins do
          [] -> ["//#{host}"]
          list -> list
        end
    end

  # Session Secure flag: default on for HTTPS / reverse-proxy TLS termination.
  # Local Docker over plain HTTP must set PHX_SECURE_COOKIES=false (compose does).
  # false / 0 / no / off → insecure cookies for HTTP-only local use only.
  session_secure? =
    System.get_env("PHX_SECURE_COOKIES", "true") not in ~w(0 false FALSE no NO off OFF)

  config :svarm, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :svarm, :session_secure, session_secure?

  config :svarm, SvarmWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: check_origin,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## Reverse proxy / TLS
  #
  # Production is expected behind HTTPS (TLS at the reverse proxy is fine).
  # Set PHX_HOST to the public hostname browsers use. Session cookies use
  # Secure by default so they are not sent over cleartext HTTP.
  #
  # Raw HTTP on a public port is unsupported. For loopback Docker demos only,
  # compose sets PHX_SECURE_COOKIES=false so LiveView sessions work on
  # http://localhost — do not use that on a shared/public host.
  #
  # App-level force_ssl may stay proxy-owned (see config/prod.exs). If the
  # proxy terminates TLS, forward Host and X-Forwarded-Proto.
  #
  # Optional app-managed HTTPS (no proxy):
  #
  #     config :svarm, SvarmWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
end
