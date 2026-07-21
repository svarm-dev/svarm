defmodule Svarm.Repo do
  use Ecto.Repo,
    otp_app: :svarm,
    adapter: Ecto.Adapters.SQLite3
end
