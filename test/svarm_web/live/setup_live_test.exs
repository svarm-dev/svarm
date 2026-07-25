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

  test "renders setup page with sections", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup")

    assert html =~ "Setup"
    assert html =~ "OpenRouter"
    assert html =~ "Tracker"
    assert html =~ "Default agent"
    assert html =~ "Apply configuration"
  end

  test "saves provider without echoing secret", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    html =
      view
      |> form("#provider-form",
        provider: %{api_key: "sk-live-test", default_model: "openrouter/free"}
      )
      |> render_submit()

    refute html =~ "sk-live-test"
    assert html =~ "Provider saved" or html =~ "•••• set" or html =~ "set"

    assert Settings.get_secret("provider.openrouter", "api_key") == "sk-live-test"
  end

  test "saves tracker local kind", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    view
    |> form("#tracker-form", tracker: %{kind: "local", owner: "", repo: "", api_key: ""})
    |> render_submit()

    assert {:ok, section} = Settings.get_section("tracker")
    assert section[:kind] == "local" or section["kind"] == "local"
  end

  test "saves default agent model", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/setup")

    view
    |> form("#agent-form", agent: %{provider: "openrouter", model: "openrouter/free"})
    |> render_submit()

    assert {:ok, agents} = Settings.get_section("agents")
    default = agents["default"]
    assert default["model"] == "openrouter/free"
  end
end
