defmodule Svarm.StreamEventTest do
  use ExUnit.Case, async: true

  alias Svarm.StreamEvent

  describe "kinds/0" do
    test "lists the locked v1 kind atoms in contract order" do
      assert StreamEvent.kinds() == [:text, :tool_start, :tool_end, :run_marker]
    end
  end

  describe "kind?/1" do
    test "accepts each v1 atom and its string name" do
      for kind <- StreamEvent.kinds() do
        assert StreamEvent.kind?(kind)
        assert StreamEvent.kind?(Atom.to_string(kind))
      end
    end

    test "rejects unknown labels and non-kind terms" do
      refute StreamEvent.kind?(:tool_fail)
      refute StreamEvent.kind?("tool_fail")
      refute StreamEvent.kind?("stdout")
      refute StreamEvent.kind?(nil)
      refute StreamEvent.kind?(42)
    end
  end

  describe "parse_kind/1" do
    test "returns {:ok, kind} for atoms and whitelist strings" do
      assert StreamEvent.parse_kind(:text) == {:ok, :text}
      assert StreamEvent.parse_kind("tool_start") == {:ok, :tool_start}
      assert StreamEvent.parse_kind("tool_end") == {:ok, :tool_end}
      assert StreamEvent.parse_kind("run_marker") == {:ok, :run_marker}
    end

    test "returns :error for unknown or non-string/atom input" do
      assert StreamEvent.parse_kind("tool_fail") == :error
      assert StreamEvent.parse_kind("TEXT") == :error
      assert StreamEvent.parse_kind(nil) == :error
      assert StreamEvent.parse_kind([]) == :error
    end

    test "does not create atoms from arbitrary strings" do
      before = :erlang.system_info(:atom_count)

      assert StreamEvent.parse_kind(
               "not_a_real_stream_kind_#{System.unique_integer([:positive])}"
             ) ==
               :error

      # Whitelist Map.fetch only — atom table must not grow from reject path.
      assert :erlang.system_info(:atom_count) == before
    end
  end

  describe "kind_string/1" do
    test "maps v1 atoms to their string names" do
      assert StreamEvent.kind_string(:text) == "text"
      assert StreamEvent.kind_string(:tool_start) == "tool_start"
      assert StreamEvent.kind_string(:tool_end) == "tool_end"
      assert StreamEvent.kind_string(:run_marker) == "run_marker"
    end

    test "returns nil for non-kinds" do
      assert StreamEvent.kind_string(:tool_fail) == nil
      assert StreamEvent.kind_string("text") == nil
    end
  end
end
