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

# Seed demo routes + boot seed (no API keys). Docker demo profile sets these.
seed_demo? = System.get_env("SVARM_SEED_DEMO") in ~w(1 true TRUE yes YES on ON)
demo_routes? = System.get_env("SVARM_DEMO_ROUTES") in ~w(1 true TRUE yes YES on ON)

if seed_demo? or demo_routes? do
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

  config :svarm, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")


  config :svarm, SvarmWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: false,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :svarm, SvarmWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :svarm, SvarmWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
