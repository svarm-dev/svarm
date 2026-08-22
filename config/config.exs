# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :svarm,
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  ecto_repos: [Svarm.Repo],
  # Sticky board Basic Auth proof TTL (seconds). Override with BOARD_AUTH_TTL_SECONDS.
  board_auth_ttl_seconds: 8 * 60 * 60

config :svarm, Svarm.Repo,
  database: Path.join(System.user_home!(), ".svarm/kanban/kanban.db"),
  journal_mode: :wal,
  # Wait up to 5s on SQLITE_BUSY so concurrent RunLog/usage/kanban writers retry.
  # ecto_sqlite3 default is 2000ms. WAL stays; do not raise pool_size as the fix.
  busy_timeout: 5_000,
  pool_size: 5

# Configure the endpoint
config :svarm, SvarmWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SvarmWeb.ErrorHTML, json: SvarmWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Svarm.PubSub,
  live_view: [signing_salt: "7TgTyug8"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  svarm: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  svarm: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
