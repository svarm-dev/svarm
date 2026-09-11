defmodule Svarm.Provider.OpenAICompatTest do
  use ExUnit.Case, async: false

  alias Svarm.Provider.{OpenAICompat, OpenRouter, Resolve}
  alias Svarm.Settings
  alias Svarm.Settings.Store

  setup do
    prev_or = System.get_env("OPENROUTER_API_KEY")
    prev_oc = System.get_env("OPENCODE_API_KEY")

    System.delete_env("OPENROUTER_API_KEY")
    System.delete_env("OPENCODE_API_KEY")
    Store.delete("provider.openrouter")
    Store.delete("provider.opencode-go")
    Store.delete("provider.opencode")

    on_exit(fn ->
      restore_env("OPENROUTER_API_KEY", prev_or)
      restore_env("OPENCODE_API_KEY", prev_oc)
      Store.delete("provider.openrouter")
      Store.delete("provider.opencode-go")
      Store.delete("provider.opencode")
    end)

    :ok
  end

  test "missing key returns {:error, :no_api_key} for every live provider" do
    for row <- Resolve.advertised() do
      {:ok, {mod, config}} = Resolve.resolve(row.id)
      assert {:error, :no_api_key} = mod.list_models(config: config)

      assert {:error, :no_api_key} =
               mod.complete("m", [%{role: "user", content: "hi"}], config: config)
    end
  end

  test "401 returns {:error, :unauthorized}" do
    System.put_env("OPENCODE_API_KEY", "sk-bad")
    {:ok, {mod, config}} = Resolve.resolve("opencode-go")

    assert {:error, :unauthorized} =
             mod.list_models(config: config, plug: &unauthorized/1)

    assert {:error, :unauthorized} =
             mod.complete("m", [%{role: "user", content: "hi"}],
               config: config,
               plug: &unauthorized/1
             )
  end

  test "capability matrix: list_models and complete succeed separately per live row" do
    System.put_env("OPENROUTER_API_KEY", "sk-or")
    System.put_env("OPENCODE_API_KEY", "sk-oc")

    for row <- Resolve.advertised() do
      {:ok, {mod, config}} = Resolve.resolve(row.id)

      assert {:ok, models} = mod.list_models(config: config, plug: &models_ok/1)
      assert models == ["stub-model"]

      assert {:ok, resp, usage} =
               mod.complete("stub-model", [%{role: "user", content: "hi"}],
                 config: config,
                 plug: &complete_ok/1
               )

      assert get_in(resp, ["choices", Access.at(0), "message", "content"]) == "ok"
      assert usage.prompt_tokens == 1
      assert usage.completion_tokens == 2
      assert usage.provider == row.id
      assert usage.provider_cost_usd == 0.01
    end
  end

  test "OpenRouter sends attribution headers; OpenCode does not" do
    System.put_env("OPENROUTER_API_KEY", "sk-or")
    System.put_env("OPENCODE_API_KEY", "sk-oc")

    {:ok, {_or_mod, or_cfg}} = Resolve.resolve("openrouter")
    {:ok, {_oc_mod, oc_cfg}} = Resolve.resolve("opencode-go")

    parent = self()

    or_plug = fn conn ->
      send(parent, {:hdrs, :openrouter, conn.req_headers})
      complete_ok(conn)
    end

    oc_plug = fn conn ->
      send(parent, {:hdrs, :opencode, conn.req_headers})
      complete_ok(conn)
    end

    assert {:ok, _, _} =
             OpenRouter.complete("m", [%{role: "user", content: "hi"}],
               config: or_cfg,
               plug: or_plug
             )

    assert {:ok, _, _} =
             OpenAICompat.complete("m", [%{role: "user", content: "hi"}],
               config: oc_cfg,
               plug: oc_plug
             )

    assert_receive {:hdrs, :openrouter, or_headers}
    assert_receive {:hdrs, :opencode, oc_headers}

    or_map = Map.new(or_headers)
    oc_map = Map.new(oc_headers)
    assert or_map["http-referer"] == "https://svarm.dev" or or_map["HTTP-Referer"]
    refute Map.has_key?(oc_map, "http-referer")
    refute Map.has_key?(oc_map, "x-openrouter-title")
  end

  test "Settings secret provider.<id> wins over shared OPENCODE_API_KEY env" do
    System.put_env("OPENCODE_API_KEY", "from-env")

    assert Settings.Resolve.provider_api_key("opencode-go") == "from-env"

    assert {:ok, _} =
             Settings.put_section("provider.opencode-go", %{"api_key" => "from-settings"})

    assert Settings.get_secret("provider.opencode-go", "api_key") == "from-settings"
    assert Settings.Resolve.provider_api_key("opencode-go") == "from-settings"
    # Shared env still serves Zen until its own Settings row is set.
    assert Settings.Resolve.provider_api_key("opencode") == "from-env"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, val), do: System.put_env(name, val)

  defp unauthorized(conn), do: Plug.Conn.send_resp(conn, 401, "")

  defp models_ok(conn) do
    json(conn, 200, %{"data" => [%{"id" => "stub-model"}]})
  end

  defp complete_ok(conn) do
    json(conn, 200, %{
      "model" => "stub-model",
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
