defmodule Svarm.RunnerTest do
  use ExUnit.Case, async: false

  alias Svarm.Runner
  alias Svarm.Test.{OsPid, Wait}

  @fake_cli Path.expand("../support/fake_cli_agent.sh", __DIR__)

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

  test "kill_tree reaps process-group descendants when pgrep is absent", %{dir: dir} do
    assert System.find_executable("kill")

    pidfile = Path.join(dir, "child.pid")
    sh = System.find_executable("sh")

    {:ok, runner} =
      Task.start(fn ->
        port_opts =
          [:binary, :exit_status, :stderr_to_stdout, {:args, [@fake_cli, "hang"]}, {:cd, dir}]
          |> Runner.maybe_add_env(%{"FAKE_CLI_PIDFILE" => pidfile})

        port = Runner.open_agent_port(sh, port_opts)

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          30_000 -> :ok
        end
      end)

    child = wait_os_pidfile(pidfile)

    os_pid =
      Wait.until(fn ->
        case Registry.lookup(Svarm.Runner.Ports, runner) do
          [{_, pid}] when is_integer(pid) -> pid
          _ -> false
        end
      end)

    assert is_integer(os_pid), "worker never registered an OS pid"

    assert match?({:ok, _}, File.read("/proc/#{os_pid}/stat")),
           "port os_pid #{os_pid} already gone"

    try do
      with_path_without_pgrep(fn ->
        assert is_nil(System.find_executable("pgrep"))
        refute is_nil(System.find_executable("kill"))
        Runner.kill_tree(os_pid)
      end)

      refute OsPid.alive_after?(child, 1_000),
             "PGID kill left descendant pid #{child} alive (leader #{os_pid})"
    after
      if Process.alive?(runner), do: Process.exit(runner, :kill)
      OsPid.kill(child)
    end
  end

  defp with_path_without_pgrep(fun) do
    tmp =
      Path.join(System.tmp_dir!(), "svarm_nopgrep_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    for name <- ["kill", "setsid", "sh", "sleep", "bash", "dash"] do
      case System.find_executable(name) do
        nil -> :ok
        path -> File.ln_s(path, Path.join(tmp, name))
      end
    end

    refute File.exists?(Path.join(tmp, "pgrep"))
    old = System.get_env("PATH")
    System.put_env("PATH", tmp)

    try do
      fun.()
    after
      if is_binary(old), do: System.put_env("PATH", old)
      File.rm_rf(tmp)
    end
  end

  defp wait_os_pidfile(path, timeout_ms \\ 2_000) do
    pid = OsPid.wait_pidfile(path, timeout_ms)
    assert is_integer(pid), "pidfile #{path} never appeared"
    pid
  end
end
