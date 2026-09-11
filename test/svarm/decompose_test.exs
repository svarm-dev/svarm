defmodule Svarm.DecomposeTest do
  use ExUnit.Case, async: false

  alias Svarm.Decompose

  test "mock mode returns deterministic tasks without calling an LLM" do
    {:ok, %{tasks: tasks, goal: goal}} =
      Decompose.run(%{goal: "ship feature X", research: "notes"}, mock: true)

    assert goal == "ship feature X"
    assert match?([_, _, _], tasks)
    assert Enum.all?(tasks, &is_map/1)
    assert Enum.at(tasks, 0).type == "research"
    assert String.contains?(Enum.at(tasks, 0).title, "ship feature X")
    assert ["demo_research", "demo_code", "demo_docs"] == Enum.map(tasks, & &1.assignee)
  end

  test "unknown provider fails closed (no OpenRouter fallback)" do
    assert {:error, :unknown_provider} =
             Decompose.run(%{goal: "ship"}, provider: "not-a-provider")
  end

  test "opencode-go complete path uses OpenAI-compat stub" do
    prev = System.get_env("OPENCODE_API_KEY")
    System.put_env("OPENCODE_API_KEY", "sk-test")

    on_exit(fn ->
      if prev,
        do: System.put_env("OPENCODE_API_KEY", prev),
        else: System.delete_env("OPENCODE_API_KEY")
    end)

    json = ~s([{"title":"one","body":"do it","type":"code","priority":1}])

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => json}}],
          "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 4, "cost" => 0.02}
        })
      )
    end

    assert {:ok, %{tasks: tasks}} =
             Decompose.run(%{goal: "ship"}, provider: "opencode-go", plug: plug)

    assert hd(tasks).title == "one"
  end
end
