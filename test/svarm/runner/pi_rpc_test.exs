defmodule Svarm.Runner.PiRPCTest do
  use ExUnit.Case, async: false

  alias Svarm.{AgentQuestion, AgentRunner, Events, Issue, KanbanBridge, RunSteer}
  alias Svarm.Runner.PiRPC
  alias Svarm.Test.OsPid

  @fake Path.expand("../../support/fake_pi_rpc.sh", __DIR__)

  defmodule StubTracker do
    def update_status(config, id, status) do
      Agent.update(config.statuses, &[{id, status} | &1])
      :ok
    end
  end

  setup do
    {:ok, statuses} = Agent.start_link(fn -> [] end)

    workspace_root =
      Path.join(System.tmp_dir!(), "svarm_pi_rpc_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    :ok = Events.subscribe()

    on_exit(fn ->
      if Process.alive?(statuses), do: Agent.stop(statuses)
      File.rm_rf(workspace_root)
    end)

    %{workspace_root: workspace_root, statuses: statuses}
  end

  defp task(id) do
    %Issue{
      id: id,
      source_id: id,
      title: "PiRPC fixture task",
      body: "do the thing",
      type: "code",
      assignee: "default",
      status: "in_progress",
      attempts: 0,
      tenant: "test"
    }
  end

  defp agent_config(mode, extra_env \\ %{}) do
    %{
      adapter: "pi_rpc",
      provider: "test",
      model: "fake",
      display_name: "FakePi",
      env: Map.merge(%{"FAKE_PI_MODE" => mode}, extra_env)
    }
  end

  defp run_opts(workspace_root, statuses, extra \\ []) do
    [
      workspace_root: workspace_root,
      tracker: StubTracker,
      tracker_config: %{statuses: statuses},
      executable: @fake,
      run_id: "run_test_#{System.unique_integer([:positive])}",
      timeout_ms: Keyword.get(extra, :timeout_ms, 5_000),
      abort_grace_ms: Keyword.get(extra, :abort_grace_ms, 500),
      settle_grace_ms: Keyword.get(extra, :settle_grace_ms, 500),
      question_timeout_ms: Keyword.get(extra, :question_timeout_ms, 15_000)
    ]
  end

  defp last_status(statuses, id) do
    Agent.get(statuses, fn list ->
      Enum.find_value(list, fn
        {^id, status} -> status
        _ -> nil
      end)
    end)
  end

  defp assert_agent_line(task_id, pattern, timeout \\ 2_000) do
    assert_receive {:agent_line, ^task_id, line}, timeout

    if line =~ pattern do
      line
    else
      assert_agent_line(task_id, pattern, timeout)
    end
  end

  defp assert_agent_line_without(task_id, pattern, forbidden, timeout \\ 2_000) do
    assert_receive {:agent_line, ^task_id, line}, timeout

    cond do
      line =~ forbidden ->
        flunk("unexpected agent line matching #{inspect(forbidden)}: #{inspect(line)}")

      line =~ pattern ->
        line

      true ->
        assert_agent_line_without(task_id, pattern, forbidden, timeout)
    end
  end

  test "fake peer is executable" do
    assert File.regular?(@fake)
    assert Bitwise.band(File.stat!(@fake).mode, 0o111) != 0
  end

  test "maybe_add_env allowlists host vars and keeps explicit overrides only" do
    System.put_env("SVARM_TEST_SECRET_XYZ", "s3cr3t")
    on_exit(fn -> System.delete_env("SVARM_TEST_SECRET_XYZ") end)

    opts = Svarm.Runner.maybe_add_env([], %{"FOO" => "bar"})
    env = Keyword.fetch!(opts, :env)
    keys = Enum.map(env, fn {k, _} -> List.to_string(k) end)

    refute "SVARM_TEST_SECRET_XYZ" in keys
    assert "FOO" in keys
    assert "PATH" in keys
  end

  test "empty env map still uses allowlist only (no full host inheritance)" do
    System.put_env("OPENROUTER_API_KEY", "sk-test-should-not-leak")
    System.put_env("SVARM_TEST_SECRET_EMPTY", "nope")

    on_exit(fn ->
      System.delete_env("OPENROUTER_API_KEY")
      System.delete_env("SVARM_TEST_SECRET_EMPTY")
    end)

    opts = Svarm.Runner.maybe_add_env([], %{})
    env = Keyword.fetch!(opts, :env)
    keys = Enum.map(env, fn {k, _} -> List.to_string(k) end)

    refute "OPENROUTER_API_KEY" in keys
    refute "SVARM_TEST_SECRET_EMPTY" in keys
    assert "PATH" in keys
  end

  test "with_github_token leaves env unchanged without App auth" do
    env = %{"FOO" => "bar", "GITHUB_TOKEN" => "pat"}
    assert env == Svarm.Runner.with_github_token(env, %{auth: :token})
    assert env == Svarm.Runner.with_github_token(env, %{})
  end

  describe "take_lines/1" do
    test "holds partial line as remainder" do
      assert {"{\"a\":", []} = PiRPC.take_lines("{\"a\":")
    end

    test "emits complete lines and keeps trailing partial" do
      assert {"partial", ["one", "two"]} = PiRPC.take_lines("one\ntwo\npartial")
    end

    test "drops oversized complete lines" do
      huge = String.duplicate("x", 1_000_001)
      assert {"", []} = PiRPC.take_lines(huge <> "\n")
    end
  end

  test "happy path: prompt → settle → :ok / review", %{workspace_root: root, statuses: statuses} do
    assert :ok = PiRPC.run(task("sva_happy"), agent_config("happy"), run_opts(root, statuses))
    assert last_status(statuses, "sva_happy") == "review"
    assert_agent_line("sva_happy", "hello from fake pi")
  end

  test "workspace run.log is redacted on disk", %{workspace_root: root, statuses: statuses} do
    id = "sva_secrets_disk"
    assert :ok = PiRPC.run(task(id), agent_config("secrets"), run_opts(root, statuses))
    assert last_status(statuses, id) == "review"

    log_path = Path.join([root, id, "run.log"])
    assert File.exists?(log_path), "expected run.log under workspace"
    on_disk = File.read!(log_path)

    refute on_disk =~ "SECRETVALUE"
    refute on_disk =~ "github_pat_11AAAA_SECRET"
    assert on_disk =~ "OPENROUTER_API_KEY=[redacted]"
    assert on_disk =~ "GITHUB_TOKEN=[redacted]"
  end

  test "timeout: wall-clock abort/kill → error, no zombie", %{
    workspace_root: root,
    statuses: statuses
  } do
    pidfile = Path.join(root, "hang.pid")

    assert {:error, {:pi, :timeout}} =
             PiRPC.run(
               task("sva_timeout"),
               agent_config("hang", %{"FAKE_PI_PIDFILE" => pidfile}),
               run_opts(root, statuses, timeout_ms: 400, abort_grace_ms: 200)
             )

    assert last_status(statuses, "sva_timeout") == "failed"
    assert_agent_line("sva_timeout", "timeout, aborting")

    assert File.exists?(pidfile), "fake peer should have written pidfile after prompt"
    pid = pidfile |> File.read!() |> String.trim() |> String.to_integer()

    # Kernel may take a beat to reap; poll /proc.
    refute OsPid.alive_after?(pid, 1_000), "zombie peer pid #{pid} still alive"

    leftover = list_fake_pids()
    refute pid in leftover, "pgrep still sees hang peer #{pid}: #{inspect(leftover)}"
  end

  test "stall: kill-tree reaps hang child", %{workspace_root: root, statuses: statuses} do
    pidfile = Path.join(root, "stall.pid")

    {:ok, runner} =
      Task.start(fn ->
        PiRPC.run(
          task("sva_stall"),
          agent_config("hang", %{"FAKE_PI_PIDFILE" => pidfile}),
          run_opts(root, statuses, timeout_ms: 30_000, abort_grace_ms: 5_000)
        )
      end)

    pid = wait_os_pidfile(pidfile)

    try do
      # Facade without Process.exit — child death must not depend on the DOWN reaper.
      assert :ok = AgentRunner.kill_os_tree(runner)
      refute OsPid.alive_after?(pid, 1_000), "kill_os_tree left hang child pid #{pid} alive"
    after
      if Process.alive?(runner), do: Process.exit(runner, :kill)
      OsPid.kill(pid)
    end
  end

  test "crash exit without settle → failed + board line", %{
    workspace_root: root,
    statuses: statuses
  } do
    assert {:error, {:pi, {:exit, 1}}} =
             PiRPC.run(task("sva_crash"), agent_config("crash"), run_opts(root, statuses))

    assert last_status(statuses, "sva_crash") == "failed"
    assert_agent_line("sva_crash", "process exited 1")
  end

  test "extension_ui_request parks, answer injects, run continues to review", %{
    workspace_root: root,
    statuses: statuses
  } do
    kb = KanbanBridge.create_task(%{title: "ui ask", status: "in_progress", assignee: "demo"})
    id = kb.id

    runner =
      Task.async(fn ->
        PiRPC.run(task(id), agent_config("ui"), run_opts(root, statuses))
      end)

    assert_agent_line(id, "waiting for answer")
    assert_pending_question(id, "proceed?")

    assert {:ok, :injected} = AgentQuestion.answer(id, %{confirmed: true})
    assert :ok = Task.await(runner, 5_000)
    assert last_status(statuses, id) == "review"
    assert KanbanBridge.get_task(id).pending_question == nil
    assert_agent_line(id, "got answer")
  end

  test "mailbox steer during parked dialog is not written to pi", %{
    workspace_root: root,
    statuses: statuses
  } do
    kb =
      KanbanBridge.create_task(%{
        title: "steer during wait",
        status: "in_progress",
        assignee: "demo"
      })

    id = kb.id

    runner =
      Task.async(fn ->
        PiRPC.run(task(id), agent_config("ui"), run_opts(root, statuses))
      end)

    assert_agent_line(id, "waiting for answer")
    assert_pending_question(id, "proceed?")
    assert_steer_inbox(id)

    # inject/2 already refuses once parked; send the leftover mailbox race.
    [{pid, _}] = Registry.lookup(RunSteer.inbox(), id)
    send(pid, {:steer, "nudge mid-dialog"})

    assert_agent_line_without(
      id,
      "steer ignored: answer the question first",
      "got steer during wait"
    )

    assert {:ok, :injected} = AgentQuestion.answer(id, %{confirmed: true})
    assert :ok = Task.await(runner, 5_000)
    assert last_status(statuses, id) == "review"
    assert_agent_line_without(id, "got answer", "got steer during wait")
  end

  test "question wait deadline sends cancelled and continues", %{
    workspace_root: root,
    statuses: statuses
  } do
    kb = KanbanBridge.create_task(%{title: "ui timeout", status: "in_progress", assignee: "demo"})
    id = kb.id

    runner =
      Task.async(fn ->
        PiRPC.run(
          task(id),
          agent_config("ui"),
          run_opts(root, statuses, question_timeout_ms: 200, timeout_ms: 5_000)
        )
      end)

    assert_agent_line(id, "waiting for answer")
    assert_agent_line(id, "question timed out, continuing")
    assert :ok = Task.await(runner, 5_000)
    assert last_status(statuses, id) == "review"
    assert KanbanBridge.get_task(id).pending_question == nil
  end

  test "abort clears wait; answer without runner is :no_runner", %{
    workspace_root: root,
    statuses: statuses
  } do
    kb = KanbanBridge.create_task(%{title: "ui abort", status: "in_progress", assignee: "demo"})
    id = kb.id

    {:ok, runner} =
      Task.start(fn ->
        PiRPC.run(
          task(id),
          agent_config("ui"),
          run_opts(root, statuses, timeout_ms: 30_000, question_timeout_ms: 30_000)
        )
      end)

    assert_agent_line(id, "waiting for answer")
    assert_pending_question(id, "proceed?")

    Process.exit(runner, :stall)
    assert_wait_cleared(id)

    # Abort clears durable wait; a leftover persist without a runner is :no_runner
    # (covered in AgentQuestionTest). After clear, answer is :not_waiting.
    assert {:error, :not_waiting} = AgentQuestion.answer(id, %{confirmed: true})
  end

  test "invalid dialog UI fails the run instead of stalling", %{
    workspace_root: root,
    statuses: statuses
  } do
    assert {:error, {:pi, :ui_request}} =
             PiRPC.run(
               task("sva_ui_invalid"),
               agent_config("ui_invalid"),
               run_opts(root, statuses, timeout_ms: 30_000)
             )

    assert last_status(statuses, "sva_ui_invalid") == "failed"
    assert_agent_line("sva_ui_invalid", "invalid UI request")
  end

  test "fire-and-forget UI does not fail the run", %{
    workspace_root: root,
    statuses: statuses
  } do
    assert :ok = PiRPC.run(task("sva_notify"), agent_config("notify"), run_opts(root, statuses))
    assert last_status(statuses, "sva_notify") == "review"
    assert_agent_line("sva_notify", "UI notify (no response)")
  end

  test "steer injects JSONL and continues to review", %{workspace_root: root, statuses: statuses} do
    kb = KanbanBridge.create_task(%{title: "steer me", status: "in_progress", assignee: "demo"})
    id = kb.id

    runner =
      Task.async(fn ->
        PiRPC.run(task(id), agent_config("steer"), run_opts(root, statuses))
      end)

    assert_steer_inbox(id)
    assert {:ok, :injected} = RunSteer.inject(id, "try the other approach")
    assert :ok = Task.await(runner, 5_000)
    assert last_status(statuses, id) == "review"
    assert_agent_line(id, "[board] steered: try the other approach")
    assert_agent_line(id, "got steer")
  end

  test "rejected steer does not fail the run", %{workspace_root: root, statuses: statuses} do
    kb =
      KanbanBridge.create_task(%{title: "steer reject", status: "in_progress", assignee: "demo"})

    id = kb.id

    runner =
      Task.async(fn ->
        PiRPC.run(task(id), agent_config("steer_reject"), run_opts(root, statuses))
      end)

    assert_steer_inbox(id)
    assert {:ok, :injected} = RunSteer.inject(id, "nudge")
    assert :ok = Task.await(runner, 5_000)
    assert last_status(statuses, id) == "review"
    assert_agent_line(id, "steer rejected")
  end

  test "protocol response success:false → failed + board line", %{
    workspace_root: root,
    statuses: statuses
  } do
    assert {:error, {:pi, :protocol}} =
             PiRPC.run(task("sva_proto"), agent_config("protocol"), run_opts(root, statuses))

    assert last_status(statuses, "sva_proto") == "failed"
    assert_agent_line("sva_proto", "protocol error")
  end

  test "malformed line does not kill happy session", %{workspace_root: root, statuses: statuses} do
    assert :ok =
             PiRPC.run(task("sva_malformed"), agent_config("malformed"), run_opts(root, statuses))

    assert last_status(statuses, "sva_malformed") == "review"
  end

  test "missing executable → failed with not_on_path + board line", %{
    workspace_root: root,
    statuses: statuses
  } do
    opts =
      run_opts(root, statuses)
      |> Keyword.put(:executable, Path.join(root, "no-such-pi-binary"))

    assert {:error, {:pi, :not_on_path}} =
             PiRPC.run(task("sva_missing"), agent_config("happy"), opts)

    assert last_status(statuses, "sva_missing") == "failed"
    assert_agent_line("sva_missing", "pi not found on PATH")
  end

  defp assert_steer_inbox(id, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      found = Registry.lookup(RunSteer.inbox(), id) != []
      Process.sleep(20)
      found
    end)
    |> Enum.reduce_while(false, fn found, _ ->
      cond do
        found ->
          {:halt, true}

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("RunSteer inbox never registered for #{id}")

        true ->
          {:cont, false}
      end
    end)
  end

  defp assert_pending_question(id, prompt, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      q = KanbanBridge.get_task(id).pending_question
      Process.sleep(20)
      q
    end)
    |> Enum.reduce_while(nil, fn q, _ ->
      cond do
        match?(%{"prompt" => ^prompt}, q) ->
          {:halt, q}

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("pending_question for #{id} never matched #{inspect(prompt)}")

        true ->
          {:cont, nil}
      end
    end)
  end

  defp assert_wait_cleared(id, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      q = KanbanBridge.get_task(id).pending_question
      Process.sleep(20)
      q
    end)
    |> Enum.reduce_while(true, fn q, _ ->
      cond do
        is_nil(q) ->
          {:halt, :ok}

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("pending_question for #{id} still set: #{inspect(q)}")

        true ->
          {:cont, true}
      end
    end)
  end

  defp list_fake_pids do
    case System.cmd("pgrep", ["-f", "fake_pi_rpc.sh"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> Enum.flat_map(&parse_pid/1)
      _ -> []
    end
  end

  defp parse_pid(s) do
    case Integer.parse(s) do
      {n, ""} -> [n]
      _ -> []
    end
  end

  defp wait_os_pidfile(path, timeout_ms \\ 2_000) do
    pid = OsPid.wait_pidfile(path, timeout_ms)
    assert is_integer(pid), "pidfile #{path} never appeared"
    pid
  end
end
