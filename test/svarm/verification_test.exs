defmodule Svarm.VerificationTest do
  use ExUnit.Case, async: true

  alias Svarm.Verification

  describe "verdict/2" do
    test "pass: agent ok and a completed recipe with exit 0" do
      assert Verification.verdict(:ok, {:ok, %{command: ["mix", "precommit"], exit_code: 0}}) ==
               :pass
    end

    test "failure: a completed recipe with a non-zero exit is a fail" do
      assert Verification.verdict(:ok, {:ok, %{command: ["mix", "precommit"], exit_code: 2}}) ==
               :fail
    end

    test "missing recipe is not_configured, not a pass" do
      assert Verification.verdict(:ok, :not_configured) == :not_configured
    end

    test "agent failure stays a failure even when the recipe exits 0" do
      recipe = {:ok, %{command: ["mix", "precommit"], exit_code: 0}}

      assert Verification.verdict({:error, {:agent_exit, 1, ""}}, recipe) == :fail
    end

    test "a recipe without an exit code is unavailable, not a pass" do
      assert Verification.verdict(:ok, {:error, :spawn_failed}) == :unavailable
      assert Verification.verdict(:ok, {:error, :timeout}) == :unavailable
    end

    test "a run that predates verification is unavailable, not a pass" do
      assert Verification.verdict(:ok, :unavailable) == :unavailable
    end
  end
end
