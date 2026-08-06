defmodule Svarm.CiResumeTest do
  use ExUnit.Case, async: false

  alias Svarm.CiResume

  setup do
    prev_enabled = System.get_env("SVARM_CI_RESUME_ENABLED")
    prev_max = System.get_env("SVARM_CI_RESUME_MAX_ATTEMPTS")

    on_exit(fn ->
      restore_env("SVARM_CI_RESUME_ENABLED", prev_enabled)
      restore_env("SVARM_CI_RESUME_MAX_ATTEMPTS", prev_max)
    end)

    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  @caps %{enabled: true, max_attempts: 3, skip_draft: true}

  test "disabled always noop" do
    coord = %{ci_resume_count: 0, ci_last_head_sha: nil, ci_circuit_open: false}
    summary = %{conclusion: :failed, head_sha: "a"}
    assert CiResume.evaluate(coord, summary, %{@caps | enabled: false}) == :noop
  end

  test "wait while in_progress or pending" do
    coord = %{ci_resume_count: 0, ci_last_head_sha: nil, ci_circuit_open: false}

    assert CiResume.evaluate(coord, %{conclusion: :in_progress, head_sha: "a"}, @caps) == :wait
    assert CiResume.evaluate(coord, %{conclusion: :pending, head_sha: "a"}, @caps) == :wait
  end

  test "noop on passed" do
    coord = %{ci_resume_count: 0, ci_last_head_sha: nil, ci_circuit_open: false}
    assert CiResume.evaluate(coord, %{conclusion: :passed, head_sha: "a"}, @caps) == :noop
  end

  test "resume once on first failure" do
    coord = %{ci_resume_count: 0, ci_last_head_sha: nil, ci_circuit_open: false}
    assert CiResume.evaluate(coord, %{conclusion: :failed, head_sha: "sha1"}, @caps) == :resume
  end

  test "same head_sha does not re-fire" do
    coord = %{ci_resume_count: 1, ci_last_head_sha: "sha1", ci_circuit_open: false}
    assert CiResume.evaluate(coord, %{conclusion: :failed, head_sha: "sha1"}, @caps) == :noop
  end

  test "new head_sha resumes while under N" do
    coord = %{ci_resume_count: 1, ci_last_head_sha: "sha1", ci_circuit_open: false}
    assert CiResume.evaluate(coord, %{conclusion: :failed, head_sha: "sha2"}, @caps) == :resume
  end

  test "circuit_open when count >= max_attempts" do
    coord = %{ci_resume_count: 3, ci_last_head_sha: "old", ci_circuit_open: false}

    assert CiResume.evaluate(coord, %{conclusion: :failed, head_sha: "new"}, @caps) ==
             :circuit_open
  end

  test "noop when circuit already open" do
    coord = %{ci_resume_count: 0, ci_last_head_sha: nil, ci_circuit_open: true}
    assert CiResume.evaluate(coord, %{conclusion: :failed, head_sha: "a"}, @caps) == :noop
  end

  test "load_caps defaults disabled" do
    System.delete_env("SVARM_CI_RESUME_ENABLED")
    System.delete_env("SVARM_CI_RESUME_MAX_ATTEMPTS")
    caps = CiResume.load_caps(nil)
    assert caps.enabled == false
    assert caps.max_attempts == 3
    assert caps.skip_draft == true
  end

  test "load_caps from workflow and env" do
    System.delete_env("SVARM_CI_RESUME_ENABLED")
    caps = CiResume.load_caps(%{"ci_resume" => %{"enabled" => true, "max_attempts" => 5}})
    assert caps.enabled == true
    assert caps.max_attempts == 5

    System.put_env("SVARM_CI_RESUME_ENABLED", "true")
    System.put_env("SVARM_CI_RESUME_MAX_ATTEMPTS", "2")

    caps2 = CiResume.load_caps(%{"ci_resume" => %{"enabled" => false, "max_attempts" => 9}})
    assert caps2.enabled == true
    assert caps2.max_attempts == 2

    System.delete_env("SVARM_CI_RESUME_ENABLED")
    System.delete_env("SVARM_CI_RESUME_MAX_ATTEMPTS")
  end

  test "context_summary includes failed names" do
    text =
      CiResume.context_summary(%{
        summary: "CI failed: mix",
        failed_names: ["mix", "credo"],
        head_sha: "abc123"
      })

    assert text =~ "CI feedback"
    assert text =~ "mix"
    assert text =~ "credo"
    assert text =~ "abc123"
  end
end
