defmodule Svarm.Provider.ResolveTest do
  use ExUnit.Case, async: false

  alias Svarm.Provider.{OpenAICompat, OpenRouter, Resolve}
  alias Svarm.Settings
  alias Svarm.Settings.Store

  setup do
    Store.delete("agents")
    on_exit(fn -> Store.delete("agents") end)
    :ok
  end

  test "advertised live rows expose required fields and skip stubs" do
    ids = Enum.map(Resolve.advertised(), & &1.id)
    assert ids == ["opencode", "opencode-go", "openrouter"]
    refute "anthropic" in ids
    refute "openai" in ids

    for row <- Resolve.advertised() do
      assert is_binary(row.id) and row.id != ""
      assert is_binary(row.base_url) and row.base_url != ""
      assert is_binary(row.auth_env) and row.auth_env != ""
      assert is_binary(row.adapter) and row.adapter != ""
      assert is_binary(row.default_model) and row.default_model != ""
    end
  end

  test "unset provider resolves to OpenRouter" do
    assert {:ok, {OpenRouter, config}} = Resolve.adapter_and_config([])
    assert config.id == "openrouter"
    assert config.adapter == "openrouter"
  end

  test "opencode-go resolves to OpenAICompat" do
    assert {:ok, {OpenAICompat, config}} = Resolve.adapter_and_config(provider: "opencode-go")
    assert config.id == "opencode-go"
    assert config.adapter == "openai_compat"
    assert config.auth_env == "OPENCODE_API_KEY"
    assert config.base_url == "https://opencode.ai/zen/go/v1"
    assert config.messages_models == ["minimax-", "qwen"]
    assert config.chat_models == []
  end

  test "opencode (Zen) resolves to OpenAICompat" do
    assert {:ok, {OpenAICompat, config}} = Resolve.adapter_and_config(provider: "opencode")
    assert config.id == "opencode"
    assert config.base_url == "https://opencode.ai/zen/v1"
    assert config.auth_env == "OPENCODE_API_KEY"
    assert config.messages_models == ["qwen"]
    assert config.chat_models == ["qwen3.8-max"]
  end

  test "Go MiniMax/Qwen are /messages; Zen MiniMax and qwen3.8-max stay chat" do
    go = Resolve.entry("opencode-go")
    zen = Resolve.entry("opencode")

    assert Resolve.messages_model?(go, "minimax-m3")
    assert Resolve.messages_model?(go, "minimax-m2.7")
    assert Resolve.messages_model?(go, "qwen3.8-max")
    assert Resolve.messages_model?(go, "qwen3.8-flash")
    refute Resolve.messages_model?(go, "glm-5.3-flash")
    refute Resolve.messages_model?(go, "kimi-k2.6")

    refute Resolve.messages_model?(zen, "minimax-m3")
    refute Resolve.messages_model?(zen, "qwen3.8-max")
    assert Resolve.messages_model?(zen, "qwen3.8-flash")
    assert Resolve.messages_model?(zen, "qwen3.7-plus")
    refute Resolve.messages_model?(zen, "kimi-k2.6")

    assert Resolve.complete_module(go, "minimax-m3") == Svarm.Provider.AnthropicMessages
    assert Resolve.complete_module(go, "glm-5.3-flash") == OpenAICompat
    assert Resolve.complete_module(zen, "qwen3.8-flash") == Svarm.Provider.AnthropicMessages
    assert Resolve.complete_module(zen, "qwen3.8-max") == OpenAICompat
    assert Resolve.complete_module(zen, "minimax-m3") == OpenAICompat
  end

  test "setup chips hide ids the selected adapter cannot complete" do
    go = Resolve.entry("opencode-go")
    zen = Resolve.entry("opencode")

    assert Resolve.completable_model?(go, "minimax-m3")
    assert Resolve.completable_model?(go, "glm-5.3-flash")
    refute Resolve.completable_model?(go, "grok-4.7")
    refute Resolve.completable_model?(go, "gpt-6-luna")
    refute Resolve.completable_model?(go, "muse-spark-1.3-contributor")

    assert Resolve.completable_model?(zen, "qwen3.8-flash")
    assert Resolve.completable_model?(zen, "kimi-k2.6")
    refute Resolve.completable_model?(zen, "claude-sonnet-5")
    refute Resolve.completable_model?(zen, "gemini-3.8-flash")
    refute Resolve.completable_model?(zen, "jev-1.13")
    refute Resolve.completable_model?(zen, "gpt-5.5")
  end

  test "unknown id fails closed" do
    assert {:error, :unknown_provider} = Resolve.adapter_and_config(provider: "not-a-provider")
    assert {:error, :unknown_provider} = Resolve.resolve("anthropic")
  end

  test "settings default-agent provider is honored or fails closed" do
    assert {:ok, _} = Settings.put_default_agent(%{"provider" => "opencode-go"})
    assert {:ok, {OpenAICompat, %{id: "opencode-go"}}} = Resolve.adapter_and_config([])

    assert {:ok, _} = Settings.put_default_agent(%{"provider" => "unknown-id"})
    assert {:error, :unknown_provider} = Resolve.adapter_and_config([])
  end
end
