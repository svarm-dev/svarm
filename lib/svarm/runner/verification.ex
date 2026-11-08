defmodule Svarm.Runner.Verification do
  @moduledoc """
  Verification recipe execution for the runner adapters.

  A verification recipe is an argv list, never a shell string. After the agent
  exits, a runner adapter executes the run's recipe inside the run workspace
  and gets back the record for the run's evidence: the command together with
  the recipe's own exit code. The exit code is whatever the recipe process
  returned — `0` is the only pass, and a non-zero recipe exit is recorded as
  its real value, never collapsed to `1`.

  When the recipe cannot run to completion (unknown executable, spawn failure,
  timeout) no exit code exists and none is invented: the result is an error
  tuple the caller must record as unavailable evidence, not as a pass.

  Recipe output is not captured yet. The evidence record carries the command
  and exit code only; output capture lands with evidence rendering.
  """

  require Logger

  alias Svarm.Runner

  @default_timeout_ms 600_000

  @typedoc "Verification recipe as an argv list (executable first)."
  @type recipe :: [String.t()]

  @typedoc "Recorded evidence: the command and the recipe's own exit code."
  @type evidence :: %{command: recipe(), exit_code: integer()}

  @doc """
  Execute `recipe` (argv list) in `cd` and record the recipe's own exit code.

  The executable resolves like execvp with `cd` as the working directory: a
  bare name is looked up on PATH, a name with a slash resolves inside `cd`.

  Options:
  - `:timeout_ms` — abort and kill the recipe process tree after this idle
    timeout (default `#{@default_timeout_ms}`).

  Returns `{:ok, %{command: recipe, exit_code: code}}` when the recipe ran to
  completion, with `code` exactly as the recipe process returned. Returns
  `{:error, :invalid_recipe | :spawn_failed | :timeout}` otherwise, with no
  exit code attached.
  """
  @spec run(recipe(), String.t(), keyword()) ::
          {:ok, evidence()} | {:error, :invalid_recipe | :spawn_failed | :timeout}
  def run(recipe, cd, opts \\ [])

  def run([_ | _] = recipe, cd, opts) when is_binary(cd) and is_list(opts) do
    if Enum.all?(recipe, &is_binary/1) do
      do_run(recipe, cd, opts)
    else
      {:error, :invalid_recipe}
    end
  end

  def run(_recipe, _cd, _opts), do: {:error, :invalid_recipe}

  defp do_run([cmd | args] = recipe, cd, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    # Pre-spawn checks: a spawn failure must never surface as a fake exit
    # status from the port machinery (e.g. `erl_child_setup` exits 2 when the
    # working directory is missing) and be recorded as the recipe's own code.
    with true <- File.dir?(cd),
         executable when is_binary(executable) <- resolve_executable(cmd, cd) do
      port_opts =
        [:binary, :exit_status, :stderr_to_stdout, {:args, args}, {:cd, cd}, {:line, 65_000}]
        |> Runner.maybe_add_env(%{})

      drain_recipe(executable, recipe, port_opts, timeout_ms)
    else
      _ -> {:error, :spawn_failed}
    end
  end

  # Executable lookup follows execvp with the recipe's working directory: a
  # bare name resolves on PATH, a name with a slash resolves inside `cd`.
  # Never resolves slash names against the BEAM's own working directory.
  defp resolve_executable(cmd, cd) do
    if String.contains?(cmd, "/") do
      cmd |> Path.expand(cd) |> System.find_executable()
    else
      System.find_executable(cmd)
    end
  end

  defp drain_recipe(executable, recipe, port_opts, timeout_ms) do
    port = Runner.open_agent_port(executable, port_opts)
    await_exit(port, recipe, timeout_ms)
  rescue
    e in [ErlangError, File.Error] ->
      Logger.error("verification recipe spawn failed: #{inspect(e)}")
      {:error, :spawn_failed}
  end

  defp await_exit(port, recipe, timeout_ms) do
    receive do
      {^port, {:data, _data}} ->
        await_exit(port, recipe, timeout_ms)

      {^port, {:exit_status, status}} ->
        {:ok, %{command: recipe, exit_code: status}}
    after
      timeout_ms ->
        Runner.ensure_dead(port)
        {:error, :timeout}
    end
  end
end
