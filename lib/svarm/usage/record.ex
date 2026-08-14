defmodule Svarm.Usage.Record do
  @moduledoc """
  Append-only usage record. Never updated or deleted — corrections are new records.
  Stores raw token counts; cost_usd is calculated at query time from Svarm.Usage.Rates.
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "usage_records" do
    field(:run_id, :string)
    field(:task_id, :string)
    field(:tenant, :string)
    # decompose | worker | retry
    field(:source, :string)
    # openrouter | anthropic | openai
    field(:provider, :string)
    # "claude-sonnet-4-20250514"
    field(:model_id, :string)
    field(:prompt_tokens, :integer)
    field(:completion_tokens, :integer)
    field(:estimated, :boolean, default: false)
    field(:provider_cost_usd, :float)
    field(:recorded_at, :integer)
    # Wall-clock for rolling dashboard windows, daily budget, and export
    # (recorded_at is monotonic ms and resets across process restarts)
    field(:inserted_at, :utc_datetime_usec)
  end
end
