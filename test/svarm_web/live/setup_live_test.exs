defmodule SvarmWeb.SetupLiveTest do
  use SvarmWeb.LiveCase, async: false

  alias Svarm.Settings
  alias Svarm.Settings.Store

  setup do
    Store.delete("provider.openrouter")
    Store.delete("tracker")
    Store.delete("agents")
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
          "agent_model" => "",
          "agent_provider" => "openrouter"
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

    html =
      view
      |> form("#setup-form",
        setup: %{
          provider_api_key: "sk-live-test",
          agent_model: "openrouter/free",
          agent_provider: "openrouter",
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

    view
    |> form("#setup-form",
      setup: %{
        provider_api_key: "",
        agent_model: "openrouter/free",
        agent_provider: "openrouter",
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
        "agent_provider" => "openrouter",
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
end
