defmodule Svarm.Runner.VerificationTest do
  use ExUnit.Case, async: true

  alias Svarm.Runner.Verification

  @moduletag :tmp_dir

  describe "run/3 records the recipe's own exit code" do
    test "pass path: exit 0 is recorded as 0", %{tmp_dir: tmp_dir} do
      recipe = ["sh", "-c", "exit 0"]

      assert {:ok, %{command: ^recipe, exit_code: 0}} = Verification.run(recipe, tmp_dir)
    end

    test "failure path: a non-zero exit is recorded with its real value", %{tmp_dir: tmp_dir} do
      recipe = ["sh", "-c", "exit 2"]

      assert {:ok, %{command: ^recipe, exit_code: 2}} = Verification.run(recipe, tmp_dir)
    end

    test "recipe arguments are passed as argv, not a shell string", %{tmp_dir: tmp_dir} do
      recipe = ["sh", "-c", "exit 7"]

      assert {:ok, %{exit_code: 7}} = Verification.run(recipe, tmp_dir)
    end

    test "a workspace-relative executable resolves inside the working directory", %{
      tmp_dir: tmp_dir
    } do
      script = Path.join(tmp_dir, "verify.sh")
      File.write!(script, "#!/bin/sh\nexit 3\n")
      File.chmod!(script, 0o755)

      assert {:ok, %{command: ["./verify.sh"], exit_code: 3}} =
               Verification.run(["./verify.sh"], tmp_dir)
    end
  end

  describe "run/3 does not invent an exit code" do
    test "an unknown executable is a spawn failure", %{tmp_dir: tmp_dir} do
      assert {:error, :spawn_failed} =
               Verification.run(["svarm-no-such-verification-binary"], tmp_dir)
    end

    test "a missing working directory is a spawn failure", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "gone")

      assert {:error, :spawn_failed} = Verification.run(["sh", "-c", "exit 0"], missing)
    end

    test "a timeout kills the recipe without an exit code", %{tmp_dir: tmp_dir} do
      assert {:error, :timeout} =
               Verification.run(["sleep", "30"], tmp_dir, timeout_ms: 100)
    end
  end

  describe "run/3 rejects a shell string recipe" do
    test "a single string is not an argv list", %{tmp_dir: tmp_dir} do
      assert {:error, :invalid_recipe} = Verification.run("mix precommit", tmp_dir)
    end

    test "an empty recipe has no executable", %{tmp_dir: tmp_dir} do
      assert {:error, :invalid_recipe} = Verification.run([], tmp_dir)
    end

    test "non-string argv entries are rejected", %{tmp_dir: tmp_dir} do
      assert {:error, :invalid_recipe} = Verification.run(["sh", :not_a_string], tmp_dir)
    end
  end
end
