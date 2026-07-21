defmodule Svarm.ApprovalTest do
  use ExUnit.Case, async: true

  alias Svarm.Approval

  @agents %{
    "default" => %{command: "true", args: [], env: %{}},
    "cody" => %{command: "true", args: [], env: %{}}
  }

  describe "config_from_map/1" do
    test "parses mode and trusted assignees" do
      cfg =
        Approval.config_from_map(%{
          "approval" => %{
            "mode" => "untrusted",
            "trusted_assignees" => ["default", "cody"]
          }
        })

      assert cfg.mode == :untrusted
      assert MapSet.equal?(cfg.trusted_assignees, MapSet.new(["default", "cody"]))
    end

    test "unknown mode is off" do
      assert %{mode: :off} = Approval.config_from_map(%{"approval" => %{"mode" => "nope"}})
    end
  end

  describe "required?/3" do
    test "off never gates" do
      cfg = %{mode: :off, trusted_assignees: MapSet.new()}
      task = %{status: "todo", assignee: "cody", title: "x", body: ""}
      refute Approval.required?(cfg, task, @agents)
    end

    test "all gates todo tasks" do
      cfg = %{mode: :all, trusted_assignees: MapSet.new()}
      task = %{status: "todo", assignee: "default", title: "x", body: ""}
      assert Approval.required?(cfg, task, @agents)
    end

    test "does not gate in_progress" do
      cfg = %{mode: :all, trusted_assignees: MapSet.new()}
      task = %{status: "in_progress", assignee: "cody", title: "x", body: ""}
      refute Approval.required?(cfg, task, @agents)
    end

    test "untrusted skips trusted assignee" do
      cfg = %{mode: :untrusted, trusted_assignees: MapSet.new(["default"])}
      task = %{status: "todo", assignee: "default", title: "x", body: ""}
      refute Approval.required?(cfg, task, @agents)
    end

    test "untrusted gates non-trusted assignee" do
      cfg = %{mode: :untrusted, trusted_assignees: MapSet.new(["default"])}
      task = %{status: "todo", assignee: "cody", title: "x", body: ""}
      assert Approval.required?(cfg, task, @agents)
    end
  end

  describe "reject/2" do
    test "invalid to_status returns error tuple" do
      assert {:error, :invalid_status} = Approval.reject("sva_nope", "todo")
    end
  end

  describe "flash_error/1" do
    test "maps known errors" do
      assert Approval.flash_error(:not_found) =~ "not found"
      assert Approval.flash_error({:not_pending, "done"}) =~ "pending"
    end
  end
end
