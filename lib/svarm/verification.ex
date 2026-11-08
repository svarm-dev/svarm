defmodule Svarm.Verification do
  @moduledoc """
  Verification verdicts for run evidence.

  A verdict is what Svärm shows as verification evidence for a run. Only a
  completed recipe with exit 0 is a `:pass`. A completed recipe with a
  non-zero exit is `:fail`. A run with no recipe is `:not_configured`.
  Evidence that does not exist — a run that predates verification, or a
  recipe that never produced an exit code (spawn failure, timeout) — is
  `:unavailable`. No non-pass verdict may render as a pass.

  Agent failure is always `:fail`: a later recipe exit 0 never upgrades it.
  """

  alias Svarm.Runner.Verification, as: Recipe

  @typedoc "Verification verdict for a run."
  @type state :: :pass | :fail | :not_configured | :unavailable

  @typedoc """
  The recipe result: what `Svarm.Runner.Verification.run/3` returned, or
  `:not_configured` when the run has no recipe, or `:unavailable` when the
  run predates verification.
  """
  @type recipe_result ::
          {:ok, Recipe.evidence()} | {:error, term()} | :not_configured | :unavailable

  @doc """
  Verdict for a run from the agent result and the recipe result.

  `agent_result` is the runner outcome (`:ok` or `{:error, reason}`).
  `recipe_result` is `t:recipe_result/0`.
  """
  @spec verdict(:ok | {:error, term()}, recipe_result()) :: state()
  def verdict({:error, _reason}, _recipe), do: :fail

  def verdict(:ok, {:ok, %{exit_code: 0}}), do: :pass
  def verdict(:ok, {:ok, %{exit_code: code}}) when is_integer(code), do: :fail
  def verdict(:ok, {:error, _reason}), do: :unavailable
  def verdict(:ok, :not_configured), do: :not_configured
  def verdict(:ok, :unavailable), do: :unavailable
end
