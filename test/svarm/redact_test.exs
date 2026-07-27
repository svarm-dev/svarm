defmodule Svarm.RedactTest do
  use ExUnit.Case, async: true

  alias Svarm.Redact

  test "map redacts atom and string secret keys" do
    raw =
      %{
        kind: :github,
        api_key: "github_pat_SECRET",
        owner: "svarm-dev"
      }
      |> Map.put("private_key", "-----BEGIN RSA PRIVATE KEY-----")

    out = Redact.map(raw)
    assert out.api_key == "[redacted]"
    assert out["private_key"] == "[redacted]"
    assert out.owner == "svarm-dev"
    assert out.kind == :github
  end

  test "orchestrator inspect never prints tracker api_key" do
    state = %Svarm.Orchestrator{
      tracker_config: %{
        kind: :github,
        api_key: "github_pat_DO_NOT_LOG",
        owner: "svarm-dev",
        repo: "svarm"
      },
      workflow: %Svarm.Workflow{
        path: "/app/config/WORKFLOW.md",
        config: %{"tracker" => %{"api_key" => "github_pat_ALSO_SECRET"}},
        prompt_template: "hi"
      },
      agents: %{}
    }

    text = inspect(state)
    refute text =~ "github_pat_DO_NOT_LOG"
    refute text =~ "github_pat_ALSO_SECRET"
    assert text =~ "redacted"
    assert text =~ "svarm-dev"
  end
end
