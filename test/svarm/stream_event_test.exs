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
      # Global :atom_count is racy under async ExUnit (other tests create atoms).
      # Prove this label was never interned: to_existing_atom/1 must still raise.
      label = "not_a_real_stream_kind_#{System.unique_integer([:positive])}"

      assert StreamEvent.parse_kind(label) == :error
      assert_raise ArgumentError, fn -> String.to_existing_atom(label) end
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

  describe "new/2" do
    test "builds a v1 event map" do
      assert StreamEvent.new(:text, %{text: "hi"}) == %{kind: :text, payload: %{text: "hi"}}
      assert StreamEvent.new(:tool_end) == %{kind: :tool_end, payload: %{}}
    end
  end

  describe "to_text/1" do
    test "text kind returns the payload text" do
      assert StreamEvent.to_text(StreamEvent.new(:text, %{text: "chunk\n"})) == "chunk\n"
      assert StreamEvent.to_text(StreamEvent.new(:text, %{})) == ""
    end

    test "tool_start reuses LogFormat projection" do
      event = StreamEvent.new(:tool_start, %{name: "bash", args: %{"command" => "ls"}})
      assert StreamEvent.to_text(event) == "\n$ bash ls\n"
    end

    test "tool_end fail projects via LogFormat; success is empty" do
      fail = StreamEvent.new(:tool_end, %{name: "bash", status: :error, result: "boom"})
      assert StreamEvent.to_text(fail) == "\n[tool bash failed]\nboom\n"

      ok = StreamEvent.new(:tool_end, %{name: "bash", status: :ok})
      assert StreamEvent.to_text(ok) == ""
    end

    test "run_marker started and finished banners" do
      started =
        StreamEvent.new(:run_marker, %{phase: :started, label: "Demo started · attempt 1"})

      assert StreamEvent.to_text(started) == "--- Demo started · attempt 1 ---\n"

      finished = StreamEvent.new(:run_marker, %{phase: :finished, exit_code: 0})
      assert StreamEvent.to_text(finished) == "\n--- run finished (exit 0) ---\n"
    end
  end
end
