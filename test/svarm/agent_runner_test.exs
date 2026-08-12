defmodule Svarm.AgentRunnerTest do
  use ExUnit.Case, async: false

  alias Svarm.AgentRunner
  alias Svarm.Runner.{Cli, PiRPC}

  @agents_path Path.join(:code.priv_dir(:svarm), "agents.toml")
  @demo_script Path.join(:code.priv_dir(:svarm), "demo_agent.sh")

  describe "load_agents/0 and load_agents/1" do
    test "loads priv/agents.toml including demo agents without API keys" do
      agents = AgentRunner.load_agents()

      assert is_map(agents)
      assert map_size(agents) >= 1

      assert %{command: "pi", adapter: "pi_rpc"} = agents["default"]
      assert agents["default"][:provider] == "openrouter"

      for name <- ["demo", "demo_research", "demo_code", "demo_docs"] do
        cfg = Map.fetch!(agents, name)
        assert cfg.command == "sh"
        assert cfg.adapter == "cli"
        assert is_list(cfg.args)
        assert hd(cfg.args) == @demo_script
      end

      assert File.regular?(@demo_script)
    end

    test "load_agents/1 reads a custom path" do
      agents = AgentRunner.load_agents(@agents_path)
      assert Map.has_key?(agents, "default")
      assert Map.has_key?(agents, "demo")
    end

    test "missing path returns empty map via Cli then merge" do
      path =
        Path.join(
          System.tmp_dir!(),
          "svarm_missing_agents_#{System.unique_integer([:positive])}.toml"
        )

      assert AgentRunner.load_agents(path) == %{}
    end

    test "omitted skills default to empty list on all agents" do
      agents = AgentRunner.load_agents(@agents_path)

      for {_name, cfg} <- agents do
        assert cfg.skills == []
      end
    end

    test "omitted tools default to empty list and fail mode" do
      agents = AgentRunner.load_agents(@agents_path)

      for {_name, cfg} <- agents do
        assert cfg.tools == []
        assert cfg.tools_mode == :fail
      end
    end

    test "declared skills parse; blanks and non-strings dropped" do
      path =
        write_agents_toml("""
        [agent.with_skills]
        command = "echo"
        skills = [" packs/backend ", "/abs/elixir", ""]

        [agent.bad_skills]
        command = "echo"
        skills = "not-a-list"

        [agent.no_skills]
        command = "echo"
        """)

      on_exit(fn -> File.rm(path) end)

      agents = AgentRunner.load_agents(path)

      assert agents["with_skills"].skills == ["packs/backend", "/abs/elixir"]
      assert agents["bad_skills"].skills == []
      assert agents["no_skills"].skills == []
    end

    test "declared tools and tools_mode parse; bad mode fails closed to fail" do
      path =
        write_agents_toml("""
        [agent.with_tools]
        command = "echo"
        tools = [" mix ", "gh", ""]
        tools_mode = "warn"

        [agent.bad_tools]
        command = "echo"
        tools = "not-a-list"
        tools_mode = "skip"

        [agent.no_tools]
        command = "echo"
        """)

      on_exit(fn -> File.rm(path) end)

      agents = AgentRunner.load_agents(path)

      assert agents["with_tools"].tools == ["mix", "gh"]
      assert agents["with_tools"].tools_mode == :warn
      assert agents["bad_tools"].tools == []
      assert agents["bad_tools"].tools_mode == :fail
      assert agents["no_tools"].tools == []
      assert agents["no_tools"].tools_mode == :fail
    end
  end

  describe "resolve!/2" do
    setup do
      %{agents: AgentRunner.load_agents()}
    end

    test "resolves named demo agent", %{agents: agents} do
      cfg = AgentRunner.resolve!("demo_code", agents)
      assert cfg.command == "sh"
      assert cfg.display_name == "Demo Code"
      assert hd(cfg.args) == @demo_script
      assert "code" in cfg.args
    end

    test "falls back to default for blank or unknown names", %{agents: agents} do
      default = AgentRunner.resolve!("default", agents)
      assert AgentRunner.resolve!("", agents) == default
      assert AgentRunner.resolve!(nil, agents) == default
      assert AgentRunner.resolve!("no_such_agent_xyz", agents) == default
    end

    test "raises when neither name nor default exists" do
      assert_raise RuntimeError, ~r/agent_not_configured/, fn ->
        AgentRunner.resolve!("missing", %{})
      end
    end
  end

  describe "resolve_adapter/1" do
    test "maps pi_rpc to PiRPC and everything else to Cli" do
      assert AgentRunner.resolve_adapter("pi_rpc") == PiRPC
      assert AgentRunner.resolve_adapter("cli") == Cli
      assert AgentRunner.resolve_adapter(nil) == Cli
      assert AgentRunner.resolve_adapter("unknown") == Cli
    end
  end

  describe "normalize_skills/1 via Cli" do
    test "nil, non-list, and empty list become []" do
      assert Cli.normalize_skills(nil) == []
      assert Cli.normalize_skills("x") == []
      assert Cli.normalize_skills([]) == []
    end

    test "trims and drops blank or non-string entries" do
      assert Cli.normalize_skills([" a ", "", nil, 1, "b"]) == ["a", "b"]
    end
  end

  defp write_agents_toml(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "svarm_agents_skills_#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, contents)
    path
  end
end
