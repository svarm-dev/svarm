defmodule Svarm.Runner.LogFormatTest do
  use ExUnit.Case, async: true

  alias Svarm.Runner.LogFormat

  describe "unwrap/1" do
    test "returns plain binaries trimmed" do
      assert LogFormat.unwrap("  hello\n") == "hello"
    end

    test "returns nil for empty / blank" do
      assert LogFormat.unwrap("") == nil
      assert LogFormat.unwrap("   ") == nil
      assert LogFormat.unwrap(nil) == nil
      assert LogFormat.unwrap(%{"content" => []}) == nil
    end

    test "unwraps pi/MCP text content blocks from dogfood" do
      payload = %{
        "content" => [
          %{"text" => "* main\n  remotes/origin/main\n", "type" => "text"}
        ],
        "details" => %{}
      }

      assert LogFormat.unwrap(payload) == "* main\n  remotes/origin/main"
    end

    test "joins multiple text blocks" do
      payload = %{
        "content" => [
          %{"type" => "text", "text" => "line1"},
          %{"type" => "text", "text" => "line2"}
        ]
      }

      assert LogFormat.unwrap(payload) == "line1\nline2"
    end

    test "does not return inspect-style map dumps" do
      payload = %{
        "content" => [%{"text" => "pi-rpc ok\n", "type" => "text"}],
        "details" => %{}
      }

      out = LogFormat.unwrap(payload)
      refute out =~ "%{"
      assert out == "pi-rpc ok"
    end
  end

  describe "tool_fail/2" do
    test "formats failure with unwrapped body" do
      result = %{
        "content" => [
          %{
            "text" =>
              "/bin/bash: line 1: mix: command not found\n\n\nCommand exited with code 127",
            "type" => "text"
          }
        ],
        "details" => %{}
      }

      out = LogFormat.tool_fail("bash", result)
      assert out =~ "[tool bash failed]"
      assert out =~ "mix: command not found"
      assert out =~ "code 127"
      refute out =~ "%{\"content\""
    end
  end

  describe "tool_start/2" do
    test "includes command summary when present" do
      assert LogFormat.tool_start("bash", %{"command" => "ls -la"}) == "\n$ bash ls -la\n"
    end

    test "name only when no args" do
      assert LogFormat.tool_start("bash") == "\n$ bash\n"
    end
  end
end
