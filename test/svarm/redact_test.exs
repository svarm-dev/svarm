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

  test "text redacts env dumps and token shapes" do
    raw = """
    OPENROUTER_API_KEY=sk-or-v1-SECRETVALUEHERE123
    GITHUB_TOKEN=github_pat_11AAAA_SECRET
    also sk-or-v1-anothersecretvalue999 in prose
    """

    out = Redact.text(raw)
    refute out =~ "SECRETVALUE"
    refute out =~ "github_pat_11AAAA_SECRET"
    refute out =~ "anothersecretvalue"
    assert out =~ "OPENROUTER_API_KEY=[redacted]"
    assert out =~ "GITHUB_TOKEN=[redacted]"
    assert out =~ "[redacted]"
  end
end
