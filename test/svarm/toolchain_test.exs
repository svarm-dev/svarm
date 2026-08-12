defmodule Svarm.ToolchainTest do
  use ExUnit.Case, async: true

  alias Svarm.Toolchain

  # Controllable PATH lookup — never mutates real PATH.
  defp lookup_present(name), do: "/usr/bin/#{name}"
  defp lookup_missing(_name), do: nil

  defp lookup_map(present) when is_map(present) do
    fn name -> Map.get(present, name) end
  end

  describe "check/2" do
    test "empty or omitted tools is a no-op" do
      assert Toolchain.check(%{}) == :ok
      assert Toolchain.check(%{tools: []}) == :ok
      assert Toolchain.check(%{tools: nil, tools_mode: :fail}) == :ok
    end

    test "all present tools return :ok" do
      cfg = %{tools: ["mix", "node"], tools_mode: :fail}
      assert Toolchain.check(cfg, lookup: &lookup_present/1) == :ok
    end

    test "missing tools with fail mode blocks (default)" do
      cfg = %{tools: ["mix", "missing_tool_xyz"]}
      lookup = lookup_map(%{"mix" => "/bin/mix"})

      assert {:error, :toolchain_missing, ["missing_tool_xyz"], msg} =
               Toolchain.check(cfg, lookup: lookup)

      assert msg =~ "missing_tool_xyz"
      assert msg =~ "tools_mode=fail"
      assert msg =~ "not started"
    end

    test "missing tools with explicit fail mode" do
      cfg = %{tools: ["gone"], tools_mode: :fail}

      assert {:error, :toolchain_missing, ["gone"], msg} =
               Toolchain.check(cfg, lookup: &lookup_missing/1)

      assert msg =~ "this agent expects tools"
      assert msg =~ "gone"
    end

    test "missing tools with warn mode allows proceed with note" do
      cfg = %{tools: ["mix", "nope"], tools_mode: :warn}
      lookup = lookup_map(%{"mix" => "/bin/mix"})

      assert {:warn, ["nope"], msg} = Toolchain.check(cfg, lookup: lookup)
      assert msg =~ "nope"
      assert msg =~ "tools_mode=warn"
      assert msg =~ "starting anyway"
    end

    test "default lookup uses System.find_executable for a real PATH hit" do
      # `sh` is present on every target we support for the demo runner.
      assert Toolchain.check(%{tools: ["sh"]}) == :ok
    end

    test "default lookup fails closed for a nonsense tool name" do
      name = "svarm_no_such_tool_#{System.unique_integer([:positive])}"

      assert {:error, :toolchain_missing, [^name], msg} =
               Toolchain.check(%{tools: [name]})

      assert msg =~ name
    end
  end

  describe "normalize_tools/1" do
    test "nil, non-list, and empty become []" do
      assert Toolchain.normalize_tools(nil) == []
      assert Toolchain.normalize_tools("mix") == []
      assert Toolchain.normalize_tools([]) == []
    end

    test "trims and drops blank or non-string entries" do
      assert Toolchain.normalize_tools([" mix ", "", nil, 1, "gh"]) == ["mix", "gh"]
    end
  end

  describe "normalize_mode/1" do
    test "accepts warn; everything else fails closed to :fail" do
      assert Toolchain.normalize_mode(:warn) == :warn
      assert Toolchain.normalize_mode("warn") == :warn
      assert Toolchain.normalize_mode(:fail) == :fail
      assert Toolchain.normalize_mode("fail") == :fail
      assert Toolchain.normalize_mode(nil) == :fail
      assert Toolchain.normalize_mode("skip") == :fail
      assert Toolchain.normalize_mode(1) == :fail
    end
  end
end
