defmodule Svarm.Provider.AnthropicMessagesTest do
  use ExUnit.Case, async: false

  alias Svarm.Provider.{AnthropicMessages, OpenAICompat, Resolve}
  alias Svarm.Settings.Store

  setup do
    prev_oc = System.get_env("OPENCODE_API_KEY")
    System.put_env("OPENCODE_API_KEY", "sk-oc")
    Store.delete("provider.opencode-go")
    Store.delete("provider.opencode")

    on_exit(fn ->
      restore_env("OPENCODE_API_KEY", prev_oc)
      Store.delete("provider.opencode-go")
      Store.delete("provider.opencode")
    end)

    :ok
  end

  test "Go MiniMax and Qwen POST /messages with Anthropic headers" do
    {:ok, {mod, config}} = Resolve.resolve("opencode-go")
    parent = self()

    plug = fn conn ->
      send(parent, {:req, conn.method, conn.request_path, Map.new(conn.req_headers)})
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:body, Jason.decode!(body)})
      messages_ok(conn, "minimax-m3")
    end

    assert {:ok, resp, usage} =
             mod.complete("minimax-m3", [%{role: "user", content: "hi"}],
               config: config,
               plug: plug
             )

    assert_receive {:req, "POST", path, headers}
    assert String.ends_with?(path, "/messages")
    refute String.contains?(path, "chat/completions")
    assert headers["x-api-key"] == "sk-oc"
    assert headers["anthropic-version"] == "2023-06-01"

    assert_receive {:body, req}
    assert req["model"] == "minimax-m3"
    assert req["max_tokens"] == 4096
    assert hd(req["messages"])["role"] == "user"

    assert get_in(resp, ["choices", Access.at(0), "message", "content"]) == "ok"
    assert usage.prompt_tokens == 3
    assert usage.completion_tokens == 5
    assert usage.provider == "opencode-go"
    assert usage.provider_cost_usd == 0.04
    assert usage.model == "minimax-m3"

    assert {:ok, _, _} =
             mod.complete("qwen3.8-flash", [%{role: "user", content: "hi"}],
               config: config,
               plug: fn conn -> messages_ok(conn, "qwen3.8-flash") end
             )
  end

  test "Zen Qwen /messages ids POST /messages; MiniMax and qwen3.8-max stay chat" do
    {:ok, {mod, config}} = Resolve.resolve("opencode")
    parent = self()

    messages_plug = fn conn ->
      send(parent, {:path, conn.request_path})
      messages_ok(conn, "qwen3.8-flash")
    end

    chat_plug = fn conn ->
      send(parent, {:path, conn.request_path})
      chat_ok(conn, "minimax-m3")
    end

    assert {:ok, _, usage} =
             mod.complete("qwen3.8-flash", [%{role: "user", content: "hi"}],
               config: config,
               plug: messages_plug
             )

    assert_receive {:path, path}
    assert String.ends_with?(path, "/messages")
    assert usage.provider == "opencode"

    assert {:ok, _, _} =
             mod.complete("minimax-m3", [%{role: "user", content: "hi"}],
               config: config,
               plug: chat_plug
             )

    assert_receive {:path, chat_path}
    assert String.ends_with?(chat_path, "/chat/completions")

    assert {:ok, _, _} =
             mod.complete("qwen3.8-max", [%{role: "user", content: "hi"}],
               config: config,
               plug: fn conn ->
                 send(parent, {:path, conn.request_path})
                 chat_ok(conn, "qwen3.8-max")
               end
             )

    assert_receive {:path, max_path}
    assert String.ends_with?(max_path, "/chat/completions")
  end

  test "Go default glm-5.3-flash stays on chat/completions" do
    {:ok, {mod, config}} = Resolve.resolve("opencode-go")
    parent = self()

    plug = fn conn ->
      send(parent, {:path, conn.request_path})
      chat_ok(conn, "glm-5.3-flash")
    end

    assert {:ok, resp, usage} =
             mod.complete("glm-5.3-flash", [%{role: "user", content: "hi"}],
               config: config,
               plug: plug
             )

    assert_receive {:path, path}
    assert String.ends_with?(path, "/chat/completions")
    assert get_in(resp, ["choices", Access.at(0), "message", "content"]) == "ok"
    assert usage.provider_cost_usd == 0.01
  end

  test "AnthropicMessages adapter complete uses /messages directly" do
    {:ok, {_mod, config}} = Resolve.resolve("opencode-go")
    parent = self()

    plug = fn conn ->
      send(parent, {:path, conn.request_path})
      messages_ok(conn, "qwen3.7-plus")
    end

    assert {:ok, _, usage} =
             AnthropicMessages.complete("qwen3.7-plus", [%{role: "user", content: "hi"}],
               config: config,
               plug: plug
             )

    assert_receive {:path, path}
    assert String.ends_with?(path, "/messages")
    assert usage.provider_cost_usd == 0.04
  end

  test "missing usage.cost leaves provider_cost_usd nil (no invented rate)" do
    {:ok, {mod, config}} = Resolve.resolve("opencode-go")

    plug = fn conn ->
      json(conn, 200, %{
        "model" => "minimax-m3",
        "content" => [%{"type" => "text", "text" => "ok"}],
        "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
      })
    end

    assert {:ok, _, usage} =
             mod.complete("minimax-m3", [%{role: "user", content: "hi"}],
               config: config,
               plug: plug
             )

    assert usage.prompt_tokens == 1
    assert usage.completion_tokens == 2
    assert usage.provider_cost_usd == nil
  end

  test "OpenAICompat still owns the Go default complete path" do
    {:ok, {_mod, config}} = Resolve.resolve("opencode-go")
    assert Resolve.complete_module(config, config.default_model) == OpenAICompat
  end

  defp restore_env(_name, nil), do: System.delete_env("OPENCODE_API_KEY")
  defp restore_env(name, val), do: System.put_env(name, val)

  defp messages_ok(conn, model) do
    json(conn, 200, %{
      "model" => model,
      "content" => [%{"type" => "text", "text" => "ok"}],
      "usage" => %{"input_tokens" => 3, "output_tokens" => 5, "cost" => 0.04}
    })
  end

  defp chat_ok(conn, model) do
    json(conn, 200, %{
      "model" => model,
      "choices" => [%{"message" => %{"content" => "ok"}}],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2, "cost" => 0.01}
    })
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
