defmodule Svarm.RunLogTest do
  use ExUnit.Case, async: false

  alias Svarm.RunLog
  alias Svarm.RunLog.Buffer
  alias Svarm.RunLog.Buffer.Stall

  test "append + get reconstructs full transcript across many chunks" do
    task_id = "rl_multi_#{System.unique_integer([:positive])}"

    Enum.each(1..20, fn i ->
      assert :ok = RunLog.append(task_id, "line #{i}\n")
    end)

    expected = Enum.map_join(1..20, "", &"line #{&1}\n")
    assert RunLog.get(task_id) == expected
  end

  test "redaction applies before buffering / durable storage" do
    task_id = "rl_redact_#{System.unique_integer([:positive])}"
    secret_line = "export OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz123456\n"

    assert :ok = RunLog.append(task_id, secret_line)
    log = RunLog.get(task_id)

    refute log =~ "sk-abcdefghijklmnopqrstuvwxyz123456"
    assert log =~ "[redacted]" or log =~ "OPENAI_API_KEY=[redacted]"

    assert :ok = RunLog.flush(task_id)
    durable = durable_only(task_id)
    refute durable =~ "sk-abcdefghijklmnopqrstuvwxyz123456"
    assert durable =~ "[redacted]" or durable =~ "OPENAI_API_KEY=[redacted]"
  end

  test "flush makes content durable; subsequent get still complete" do
    task_id = "rl_flush_#{System.unique_integer([:positive])}"

    assert :ok = RunLog.append(task_id, "buffered-only\n")
    assert Buffer.pending(task_id) == "buffered-only\n"
    assert RunLog.get(task_id) == "buffered-only\n"

    assert :ok = RunLog.flush(task_id)
    assert Buffer.pending(task_id) == ""
    assert RunLog.get(task_id) == "buffered-only\n"

    # Direct durable path (no pending)
    assert durable_only(task_id) == "buffered-only\n"
  end

  test "get sees pending chunks before flush (late-join)" do
    {:ok, _} = Stall.start_link()
    on_exit(&Stall.stop/0)

    task_id = "rl_pending_#{System.unique_integer([:positive])}"

    assert :ok = RunLog.append(task_id, "late-join-chunk\n")
    assert RunLog.get(task_id) == "late-join-chunk\n"
    assert Buffer.pending(task_id) == "late-join-chunk\n"

    assert_receive {:persist_await, _}, 1_000
    assert durable_only(task_id) == ""
    assert RunLog.get(task_id) == "late-join-chunk\n"
  end

  test "SQL append on flush does not drop prior durable content" do
    task_id = "rl_sql_#{System.unique_integer([:positive])}"

    assert :ok = RunLog.append(task_id, "first\n")
    assert :ok = RunLog.flush(task_id)
    assert :ok = RunLog.append(task_id, "second\n")
    assert :ok = RunLog.flush(task_id)

    assert RunLog.get(task_id) == "first\nsecond\n"
    assert durable_only(task_id) == "first\nsecond\n"
  end

  test "size threshold makes chunk visible without waiting for SQLite" do
    task_id = "rl_size_#{System.unique_integer([:positive])}"
    # Buffer flushes at 4096 bytes; send one large chunk over the threshold.
    big = String.duplicate("x", 5_000)

    assert :ok = RunLog.append(task_id, big)
    assert RunLog.get(task_id) == big

    assert :ok = RunLog.flush(task_id)
    assert Buffer.pending(task_id) == ""
    assert durable_only(task_id) == big
    assert RunLog.get(task_id) == big
  end

  test "append of flush-sized chunk returns while persist is stalled" do
    {:ok, _} = Stall.start_link()
    on_exit(&Stall.stop/0)

    task_id = "rl_noblock_#{System.unique_integer([:positive])}"
    big = String.duplicate("x", 5_000)

    {elapsed_us, :ok} = :timer.tc(fn -> RunLog.append(task_id, big) end)
    # Far below SQLite busy_timeout (5s); persist is blocked on the stall gate.
    assert elapsed_us < 200_000

    assert_receive {:persist_await, _}, 1_000
    assert RunLog.get(task_id) == big
    assert Buffer.pending(task_id) == big
    assert durable_only(task_id) == ""

    Stall.release()
    assert :ok = RunLog.flush(task_id)
    assert Buffer.pending(task_id) == ""
    assert durable_only(task_id) == big
    assert RunLog.get(task_id) == big
  end

  test "append returns while the Repo checkout is held (persist path stalled)" do
    task_id = "rl_pool_#{System.unique_integer([:positive])}"
    big = String.duplicate("x", 5_000)
    parent = self()

    locker =
      Task.async(fn ->
        Svarm.Repo.checkout(fn ->
          send(parent, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :locked, 1_000

    {elapsed_us, :ok} = :timer.tc(fn -> RunLog.append(task_id, big) end)
    assert elapsed_us < 200_000
    assert Buffer.pending(task_id) == big

    send(locker.pid, :release)
    Task.await(locker)

    assert RunLog.get(task_id) == big
    assert :ok = RunLog.flush(task_id)
    assert durable_only(task_id) == big
  end

  test "concurrent multi-task appends remain ordered per task" do
    tasks =
      for i <- 1..4 do
        "rl_conc_#{i}_#{System.unique_integer([:positive])}"
      end

    tasks
    |> Task.async_stream(
      fn task_id ->
        Enum.each(1..10, fn n ->
          RunLog.append(task_id, "#{task_id}:#{n}\n")
        end)

        before_flush = RunLog.get(task_id)
        RunLog.flush(task_id)
        {task_id, before_flush, RunLog.get(task_id)}
      end,
      max_concurrency: 4,
      timeout: 5_000
    )
    |> Enum.each(fn {:ok, {task_id, before_flush, log}} ->
      expected = Enum.map_join(1..10, "", &"#{task_id}:#{&1}\n")
      assert before_flush == expected
      assert log == expected
      assert durable_only(task_id) == expected
    end)
  end

  test "concurrent append + get while persist is stalled keeps per-task order" do
    {:ok, _} = Stall.start_link()
    on_exit(&Stall.stop/0)

    tasks =
      for i <- 1..4 do
        "rl_conc_stall_#{i}_#{System.unique_integer([:positive])}"
      end

    tasks
    |> Task.async_stream(
      fn task_id ->
        Enum.each(1..10, fn n ->
          RunLog.append(task_id, "#{task_id}:#{n}\n")
        end)

        {task_id, RunLog.get(task_id)}
      end,
      max_concurrency: 4,
      timeout: 5_000
    )
    |> Enum.each(fn {:ok, {task_id, log}} ->
      expected = Enum.map_join(1..10, "", &"#{task_id}:#{&1}\n")
      assert log == expected
      assert durable_only(task_id) == ""
    end)

    Stall.release()

    Enum.each(tasks, fn task_id ->
      assert :ok = RunLog.flush(task_id)
      expected = Enum.map_join(1..10, "", &"#{task_id}:#{&1}\n")
      assert RunLog.get(task_id) == expected
      assert durable_only(task_id) == expected
    end)
  end

  test "persist_append is SQL append (no full-content read in Elixir path)" do
    task_id = "rl_persist_#{System.unique_integer([:positive])}"

    assert :ok = RunLog.persist_append(task_id, "a")
    assert :ok = RunLog.persist_append(task_id, "b")
    assert :ok = RunLog.persist_append(task_id, "c")

    assert durable_only(task_id) == "abc"
  end

  test "persist_append concatenates with SQL content || ? (no full-row rewrite)" do
    source = File.read!(Path.expand("../../lib/svarm/run_log.ex", __DIR__))
    assert source =~ ~s[fragment("content || ?", ^chunk)]
    refute source =~ ~r/def persist_append[\s\S]{0,800}<>/
  end

  defp durable_only(task_id) do
    import Ecto.Query

    case Svarm.Repo.one(from(r in RunLog, where: r.task_id == ^task_id, select: r.content)) do
      nil -> ""
      content -> content
    end
  end
end
