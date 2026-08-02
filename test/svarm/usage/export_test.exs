defmodule Svarm.Usage.ExportTest do
  use ExUnit.Case, async: false

  alias Svarm.Repo
  alias Svarm.Usage
  alias Svarm.Usage.Export

  setup do
    Repo.delete_all("usage_records")
    :ok
  end

  test "empty ledger CSV has header only" do
    csv = Export.to_csv([])
    assert csv =~ "task_id,run_id,source"

    assert String.split(String.trim(csv), "\n") == [
             "task_id,run_id,source,provider,model_id,prompt_tokens,completion_tokens,cost_usd,estimated,recorded_at,inserted_at"
           ]
  end

  test "CSV and JSON include sample rows with estimated" do
    Usage.append(%{
      run_id: "run_x",
      task_id: "task_x",
      source: "worker",
      provider: "openrouter",
      model_id: "claude-sonnet-4-20250514",
      prompt_tokens: 1000,
      completion_tokens: 100,
      estimated: false
    })

    records = Usage.list_all()
    csv = Export.to_csv(records)
    assert csv =~ "task_x"
    assert csv =~ "run_x"
    assert csv =~ "true"

    json = Export.to_json(records)
    assert json =~ "task_x"
    decoded = Jason.decode!(json)
    assert is_list(decoded)
    assert hd(decoded)["task_id"] == "task_x"
    assert hd(decoded)["estimated"] == true
  end
end
