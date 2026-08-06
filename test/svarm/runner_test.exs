defmodule Svarm.RunnerTest do
  use ExUnit.Case, async: true

  alias Svarm.Runner

  setup do
    dir =
      Path.join(System.tmp_dir!(), "svarm_runner_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "write_run_log redacts env dumps and token shapes before disk write", %{dir: dir} do
    path = Path.join(dir, "run.log")

    raw = """
    OPENROUTER_API_KEY=sk-or-v1-SECRETVALUEHERE123
    GITHUB_TOKEN=github_pat_11AAAA_SECRET
    also sk-or-v1-anothersecretvalue999 in prose
    plain agent output
    """

    assert :ok = Runner.write_run_log(path, raw)
    on_disk = File.read!(path)

    refute on_disk =~ "SECRETVALUE"
    refute on_disk =~ "github_pat_11AAAA_SECRET"
    refute on_disk =~ "anothersecretvalue"
    assert on_disk =~ "OPENROUTER_API_KEY=[redacted]"
    assert on_disk =~ "GITHUB_TOKEN=[redacted]"
    assert on_disk =~ "[redacted]"
    assert on_disk =~ "plain agent output"
  end

  test "write_run_log leaves non-secret text unchanged", %{dir: dir} do
    path = Path.join(dir, "run.log")
    text = "hello from agent\nno secrets here\n"

    assert :ok = Runner.write_run_log(path, text)
    assert File.read!(path) == text
  end
end
