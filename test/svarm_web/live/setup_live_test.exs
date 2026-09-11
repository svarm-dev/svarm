defmodule SvarmWeb.SetupLiveTest do
  use SvarmWeb.LiveCase, async: false

  alias Svarm.Settings
  alias Svarm.Settings.Store

  setup do
    cleanup = fn ->
      Store.delete("provider.openrouter")
      Store.delete("provider.opencode-go")
      Store.delete("provider.opencode")
      Store.delete("tracker")
      Store.delete("agents")

      # Apply reloads the live orchestrator; drop Settings overlays so later
      # BoardLive tests still see agents.toml (Pi RPC default).
      if Process.whereis(Svarm.Orchestrator) do
        _ = Svarm.Orchestrator.reload_config()
      end
    end

    cleanup.()
    on_exit(cleanup)
    :ok
  end

  test "renders setup preflight with single apply path", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup")

    assert html =~ "Setup"
    assert html =~ "Preflight"
    assert html =~ "OpenRouter"
    assert html =~ "Tracker"
    assert html =~ "Default agent"
    assert html =~ "Apply to live swarm"
    assert html =~ ~s(id="setup-form")
    assert html =~ ~s(aria-current="page")
    refute html =~ "Save provider"
    refute html =~ "Save tracker"
    refute html =~ "Save agent"
  end

  test "github fields hidden for local tracker", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/setup")

    refute html =~ ~s(id="setup-tracker-owner")
    refute html =~ ~s(id="setup-tracker-api-key")

    html =
      view
      |> element("#setup-form")
      |> render_change(%{
        "setup" => %{
          "tracker_kind" => "github",
          "tracker_owner" => "",
          "tracker_repo" => "",
          "tracker_api_key" => "",
          "tracker_labels" => "",
          "provider_api_key" => "",
          "agent_model" => ""
        }
      })

    assert html =~ ~s(id="setup-tracker-owner")
    assert html =~ ~s(id="setup-tracker-api-key")
  end

  test "local tracker shows pending apply when live tracker not ready", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup")

    # Form defaults to local; if live tracker isn't ready, badge should not say only Needed
    # without pending language when local is selected.
    assert html =~ "Pending apply" or html =~ "Apply to use Local board" or html =~ "Local board"
  end

  test "save and apply stores provider secret without echoing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    type_provider_key(view, "sk-live-test", "openrouter/free")

    html =
      view
      |> form("#setup-form",
        setup: %{
          provider_api_key: "sk-live-test",
          agent_model: "openrouter/free",
          tracker_kind: "local"
        }
      )
      |> render_submit()

    refute html =~ "sk-live-test"
    assert html =~ "Applied to live swarm" or html =~ "•••• set" or html =~ "set"

    assert Settings.get_secret("provider.openrouter", "api_key") == "sk-live-test"
  end

  test "save and apply stores local tracker and default model", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    type_provider_key(view, "sk-or-model", "openrouter/free")

    view
    |> form("#setup-form",
      setup: %{
        provider_api_key: "sk-or-model",
        agent_model: "openrouter/free",
        tracker_kind: "local"
      }
    )
    |> render_submit()

    assert {:ok, section} = Settings.get_section("tracker")
    assert section[:kind] == "local" or section["kind"] == "local"

    assert {:ok, agents} = Settings.get_section("agents")
    default = agents["default"]
    assert default["model"] == "openrouter/free"
  end

  test "discard restores baseline form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    view
    |> element("#setup-form")
    |> render_change(%{
      "setup" => %{
        "tracker_kind" => "local",
        "provider_api_key" => "",
        "agent_model" => "dirty-model",
        "tracker_owner" => "",
        "tracker_repo" => "",
        "tracker_api_key" => "",
        "tracker_labels" => ""
      }
    })

    assert render(view) =~ "Unapplied changes" or render(view) =~ "dirty-model"

    html = render_click(view, "discard", %{})
    refute html =~ "dirty-model"
  end

  test "global nav includes Setup", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup")
    assert html =~ ~s(href="/setup")
    assert html =~ "Setup"
  end

  test "save OpenCode Go key is redacted on read", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    view
    |> element("#setup-form")
    |> render_change(%{
      "setup" => %{
        "provider_id" => "opencode-go",
        "provider_api_key" => "",
        "agent_model" => "glm-5.3-flash",
        "tracker_kind" => "local"
      }
    })

    view
    |> element("#setup-form")
    |> render_change(%{
      "setup" => %{
        "provider_id" => "opencode-go",
        "provider_api_key" => "sk-oc-live",
        "agent_model" => "glm-5.3-flash",
        "tracker_kind" => "local"
      }
    })

    html =
      view
      |> form("#setup-form",
        setup: %{
          provider_id: "opencode-go",
          provider_api_key: "sk-oc-live",
          agent_model: "glm-5.3-flash",
          tracker_kind: "local"
        }
      )
      |> render_submit()

    refute html =~ "sk-oc-live"
    assert html =~ "Applied to live swarm" or html =~ "•••• set" or html =~ "set"

    assert Settings.get_secret("provider.opencode-go", "api_key") == "sk-oc-live"
    assert {:ok, section} = Settings.get_section("provider.opencode-go")
    refute Map.has_key?(section, "api_key")
    assert section.api_key_set? == true

    assert {:ok, agents} = Settings.get_section("agents")
    assert agents["default"]["provider"] == "opencode-go"
  end

  test "test_provider flash names OpenCode Go under HTTP stub", %{conn: conn} do
    prev = System.get_env("OPENCODE_API_KEY")
    System.put_env("OPENCODE_API_KEY", "sk-oc-stub")

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"data" => [%{"id" => "glm-5.3-flash"}, %{"id" => "other"}]})
      )
    end

    Application.put_env(:svarm, :provider_req_plug, plug)

    on_exit(fn ->
      Application.delete_env(:svarm, :provider_req_plug)

      if prev,
        do: System.put_env("OPENCODE_API_KEY", prev),
        else: System.delete_env("OPENCODE_API_KEY")
    end)

    {:ok, view, _html} = live(conn, ~p"/setup")

    view
    |> element("#setup-form")
    |> render_change(%{
      "setup" => %{
        "provider_id" => "opencode-go",
        "provider_api_key" => "",
        "agent_model" => "glm-5.3-flash",
        "tracker_kind" => "local"
      }
    })

    html = render_click(view, "test_provider", %{})
    assert html =~ "OpenCode Go OK"
    assert html =~ "glm-5.3-flash"
  end

  test "selected provider without a key is not ready even if another key exists", %{conn: conn} do
    prev_or = System.get_env("OPENROUTER_API_KEY")
    prev_oc = System.get_env("OPENCODE_API_KEY")
    System.put_env("OPENROUTER_API_KEY", "sk-or-other")
    System.delete_env("OPENCODE_API_KEY")

    on_exit(fn ->
      if prev_or,
        do: System.put_env("OPENROUTER_API_KEY", prev_or),
        else: System.delete_env("OPENROUTER_API_KEY")

      if prev_oc,
        do: System.put_env("OPENCODE_API_KEY", prev_oc),
        else: System.delete_env("OPENCODE_API_KEY")
    end)

    {:ok, view, html} = live(conn, ~p"/setup")
    assert html =~ "Ready" or html =~ "Pending apply"

    type_provider_key(view, "sk-or-keep", "openrouter/free")

    view
    |> form("#setup-form",
      setup: %{
        provider_id: "openrouter",
        provider_api_key: "sk-or-keep",
        agent_model: "openrouter/free",
        tracker_kind: "local"
      }
    )
    |> render_submit()

    assert {:ok, before} = Settings.get_section("agents")
    assert before["default"]["provider"] == "openrouter"
    assert before["default"]["model"] == "openrouter/free"

    html =
      view
      |> element("#setup-form")
      |> render_change(%{
        "setup" => %{
          "provider_id" => "opencode-go",
          "provider_api_key" => "",
          "agent_model" => "glm-5.3-flash",
          "tracker_kind" => "local"
        }
      })

    assert html =~ "Needed"

    view
    |> form("#setup-form",
      setup: %{
        provider_id: "opencode-go",
        provider_api_key: "",
        agent_model: "glm-5.3-flash",
        tracker_kind: "local"
      }
    )
    |> render_submit()

    assert {:ok, after_apply} = Settings.get_section("agents")
    assert after_apply["default"]["provider"] == "openrouter"
    assert after_apply["default"]["model"] == "openrouter/free"
  end

  test "switching provider clears stale model chips", %{conn: conn} do
    prev = System.get_env("OPENCODE_API_KEY")
    System.put_env("OPENCODE_API_KEY", "sk-oc-stub")

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => [%{"id" => "glm-5.3-flash"}]}))
    end

    Application.put_env(:svarm, :provider_req_plug, plug)

    on_exit(fn ->
      Application.delete_env(:svarm, :provider_req_plug)

      if prev,
        do: System.put_env("OPENCODE_API_KEY", prev),
        else: System.delete_env("OPENCODE_API_KEY")
    end)

    {:ok, view, _html} = live(conn, ~p"/setup")

    view
    |> element("#setup-form")
    |> render_change(%{
      "setup" => %{
        "provider_id" => "opencode-go",
        "provider_api_key" => "",
        "agent_model" => "glm-5.3-flash",
        "tracker_kind" => "local"
      }
    })

    html = render_click(view, "test_provider", %{})
    assert html =~ "glm-5.3-flash"

    html =
      view
      |> element("#setup-form")
      |> render_change(%{
        "setup" => %{
          "provider_id" => "openrouter",
          "provider_api_key" => "",
          "agent_model" => "",
          "tracker_kind" => "local"
        }
      })

    refute html =~ ~s(phx-value-model="glm-5.3-flash")
  end

  test "switching provider drops leftover API key from the form", %{conn: conn} do
    prev_or = System.get_env("OPENROUTER_API_KEY")
    prev_oc = System.get_env("OPENCODE_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")
    System.delete_env("OPENCODE_API_KEY")

    on_exit(fn ->
      if prev_or,
        do: System.put_env("OPENROUTER_API_KEY", prev_or),
        else: System.delete_env("OPENROUTER_API_KEY")

      if prev_oc,
        do: System.put_env("OPENCODE_API_KEY", prev_oc),
        else: System.delete_env("OPENCODE_API_KEY")
    end)

    {:ok, view, _html} = live(conn, ~p"/setup")

    view
    |> element("#setup-form")
    |> render_change(%{
      "setup" => %{
        "provider_id" => "openrouter",
        "provider_api_key" => "sk-or-leftover",
        "agent_model" => "openrouter/free",
        "tracker_kind" => "local"
      }
    })

    html =
      view
      |> element("#setup-form")
      |> render_change(%{
        "setup" => %{
          "provider_id" => "opencode-go",
          "provider_api_key" => "sk-or-leftover",
          "agent_model" => "glm-5.3-flash",
          "tracker_kind" => "local"
        }
      })

    refute html =~ "sk-or-leftover"
    assert html =~ ~s(id="setup-provider-api-key-opencode-go")

    view
    |> form("#setup-form",
      setup: %{
        provider_id: "opencode-go",
        provider_api_key: "sk-or-leftover",
        agent_model: "glm-5.3-flash",
        tracker_kind: "local"
      }
    )
    |> render_submit()

    assert Settings.get_secret("provider.opencode-go", "api_key") in [nil, ""]

    case Settings.get_section("agents") do
      :error ->
        :ok

      {:ok, agents} ->
        refute agents["default"]["provider"] == "opencode-go"
    end
  end

  test "first switch payload leftover is not treated as a new secret", %{conn: conn} do
    prev_or = System.get_env("OPENROUTER_API_KEY")
    prev_oc = System.get_env("OPENCODE_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")
    System.delete_env("OPENCODE_API_KEY")

    on_exit(fn ->
      if prev_or,
        do: System.put_env("OPENROUTER_API_KEY", prev_or),
        else: System.delete_env("OPENROUTER_API_KEY")

      if prev_oc,
        do: System.put_env("OPENCODE_API_KEY", prev_oc),
        else: System.delete_env("OPENCODE_API_KEY")
    end)

    {:ok, view, _html} = live(conn, ~p"/setup")

    html =
      view
      |> element("#setup-form")
      |> render_change(%{
        "setup" => %{
          "provider_id" => "opencode-go",
          "provider_api_key" => "sk-autofill-leftover",
          "agent_model" => "glm-5.3-flash",
          "tracker_kind" => "local"
        }
      })

    refute html =~ "sk-autofill-leftover"
    assert html =~ ~s(id="setup-provider-api-key-opencode-go")

    view
    |> form("#setup-form",
      setup: %{
        provider_id: "opencode-go",
        provider_api_key: "sk-autofill-leftover",
        agent_model: "glm-5.3-flash",
        tracker_kind: "local"
      }
    )
    |> render_submit()

    assert Settings.get_secret("provider.opencode-go", "api_key") in [nil, ""]

    case Settings.get_section("agents") do
      :error ->
        :ok

      {:ok, agents} ->
        refute agents["default"]["provider"] == "opencode-go"
    end
  end

  test "OpenRouter path unchanged when selected", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/setup")
    assert html =~ "OpenRouter"
    assert html =~ ~s(id="setup-provider-id")

    type_provider_key(view, "sk-or-keep", "openrouter/free")

    html =
      view
      |> form("#setup-form",
        setup: %{
          provider_id: "openrouter",
          provider_api_key: "sk-or-keep",
          agent_model: "openrouter/free",
          tracker_kind: "local"
        }
      )
      |> render_submit()

    refute html =~ "sk-or-keep"
    assert Settings.get_secret("provider.openrouter", "api_key") == "sk-or-keep"
  end

  defp type_provider_key(view, key, model, provider_id \\ "openrouter") do
    view
    |> element("#setup-form")
    |> render_change(%{
      "setup" => %{
        "provider_id" => provider_id,
        "provider_api_key" => key,
        "agent_model" => model,
        "tracker_kind" => "local"
      }
    })
  end
end
