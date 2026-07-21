import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :svarm, SvarmWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Wtkvnaeylhe2WRjcDOQi1CWXVrpKZ09CnZO9YnfaNna5H+0rE6vVfx5bxUMFzqdZ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Allow /approvals in ConnCase without production Basic Auth
config :svarm, dev_routes: true

config :svarm, Svarm.Repo,
  database: Path.join(System.tmp_dir!(), "svarm_test_\#{System.system_time(:second)}.db"),
  pool_size: 1,
  show_sensitive_data_on_connection_error: true
