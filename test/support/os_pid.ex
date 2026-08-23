defmodule Svarm.Test.OsPid do
  @moduledoc false

  alias Svarm.Test.Wait

  @doc "Poll a pidfile until it contains an integer pid, or return false."
  def wait_pidfile(path, timeout_ms \\ 2_000) do
    Wait.until(fn -> read_pidfile(path) end, attempts: max(div(timeout_ms, 25), 1))
  end

  def read_pidfile(path) do
    case File.read(path) do
      {:ok, body} -> parse_pid(body)
      _ -> false
    end
  end

  def kill(pid) when is_integer(pid) do
    case System.find_executable("kill") do
      nil ->
        :ok

      kill ->
        _ = System.cmd(kill, ["-KILL", "--", Integer.to_string(pid)], stderr_to_stdout: true)
    end
  end

  def alive_after?(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_alive?(pid, deadline)
  end

  defp parse_pid(body) do
    case Integer.parse(String.trim(body)) do
      {n, ""} -> n
      _ -> false
    end
  end

  defp poll_alive?(pid, deadline) do
    alive? = match?({:ok, _}, File.read("/proc/#{pid}/stat"))

    cond do
      not alive? ->
        false

      System.monotonic_time(:millisecond) >= deadline ->
        true

      true ->
        Process.sleep(50)
        poll_alive?(pid, deadline)
    end
  end
end
