defmodule Svarm.Usage.Receipt do
  @moduledoc """
  Classifies a usage summary plus a liveness fact into one receipt.

  Templates call `label/3` and print `text`. They do not rebuild a dollar from
  `estimated` and `record_count`. Budget keeps reading `total_cost_usd`.
  """

  @enforce_keys [:state, :lower_bound_usd, :basis, :reasons, :rows]
  defstruct [:state, :lower_bound_usd, :basis, :reasons, :rows]

  @type liveness :: :running | :settled
  @type reason :: :running | :no_usage | :unpriced
  @type variant :: :badge | :detail | :markdown
  @type summary :: %{
          required(:total_cost_usd) => float(),
          required(:estimated) => boolean(),
          required(:record_count) => non_neg_integer(),
          required(:unmetered_rows) => non_neg_integer(),
          required(:unpriced_rows) => non_neg_integer(),
          optional(atom()) => term()
        }

  @type t :: %__MODULE__{
          state: :empty | :measured | :estimated | :partial,
          lower_bound_usd: float(),
          basis: :measured | :estimated,
          reasons: [reason()],
          rows: non_neg_integer()
        }

  @type label :: %{
          text: String.t(),
          title: String.t(),
          tone: :measured | :estimated | :partial | :empty,
          show?: boolean()
        }

  @reason_text %{
    running: "running",
    no_usage: "adapter does not report usage",
    unpriced: "unpriced model"
  }

  @doc """
  Classify `(summary, liveness)`.

  Reasons are collected first. Any reason is `:partial`. A zero row count with
  no reason is `:empty`. `nil` is an empty summary, so a live attempt with no
  rows is `:partial`, not hidden.
  """
  @spec classify(summary() | nil, liveness()) :: t()
  def classify(summary, liveness) when liveness in [:running, :settled] do
    summary = summary || empty_summary()
    reasons = reasons(summary, liveness)
    rows = int(summary, :record_count)
    estimated? = Map.get(summary, :estimated) == true
    basis = if estimated?, do: :estimated, else: :measured

    state =
      cond do
        reasons != [] -> :partial
        rows == 0 -> :empty
        estimated? -> :estimated
        true -> :measured
      end

    %__MODULE__{
      state: state,
      lower_bound_usd: float(summary, :total_cost_usd),
      basis: basis,
      reasons: reasons,
      rows: rows
    }
  end

  @doc """
  `classify/2` then format. `per:` divides the lower bound (the $/merged case).

  `:badge` hides an empty receipt. `:detail` and `:markdown` print
  `no usage recorded` with no dollar.
  """
  @spec label(summary() | nil, liveness(), variant(), keyword()) :: label()
  def label(summary, liveness, variant, opts \\ [])
      when variant in [:badge, :detail, :markdown] and is_list(opts) do
    summary
    |> classify(liveness)
    |> divide(Keyword.get(opts, :per))
    |> format(variant)
  end

  @doc """
  Sum summaries. `estimated` is OR. `combine([])` is the empty summary.
  """
  @spec combine([summary()]) :: summary()
  def combine(summaries) when is_list(summaries) do
    Enum.reduce(summaries, empty_summary(), fn summary, acc ->
      %{
        total_cost_usd:
          Float.round(float(acc, :total_cost_usd) + float(summary, :total_cost_usd), 4),
        estimated: acc.estimated or Map.get(summary, :estimated) == true,
        record_count: int(acc, :record_count) + int(summary, :record_count),
        unmetered_rows: int(acc, :unmetered_rows) + int(summary, :unmetered_rows),
        unpriced_rows: int(acc, :unpriced_rows) + int(summary, :unpriced_rows),
        prompt_tokens: float(acc, :prompt_tokens) + float(summary, :prompt_tokens),
        completion_tokens: float(acc, :completion_tokens) + float(summary, :completion_tokens)
      }
    end)
  end

  @doc "Zero summary. Session and window queries return this shape when the ledger is empty."
  @spec empty_summary() :: summary()
  def empty_summary do
    %{
      total_cost_usd: 0.0,
      estimated: false,
      record_count: 0,
      unmetered_rows: 0,
      unpriced_rows: 0,
      prompt_tokens: 0,
      completion_tokens: 0
    }
  end

  @doc """
  ROI denominator note. Nil when `partial_tasks` is 0.

  `coverage_note(2, 3, 1)` is
  `2/3 tasks with ledger activity; denominator includes 1 task with 1 unmeasured run`.
  The includes-clause counts are `unmeasured_runs`.
  """
  @spec coverage_note(non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          String.t() | nil
  def coverage_note(partial_tasks, tasks_with_activity, unmeasured_runs)
      when is_integer(partial_tasks) and partial_tasks > 0 and
             is_integer(tasks_with_activity) and tasks_with_activity >= 0 and
             is_integer(unmeasured_runs) and unmeasured_runs >= 0 do
    fraction = "#{partial_tasks}/#{tasks_with_activity} tasks with ledger activity"
    included = phrase(unmeasured_runs, "task", "tasks")
    runs = phrase(unmeasured_runs, "unmeasured run", "unmeasured runs")
    fraction <> "; denominator includes " <> included <> " with " <> runs
  end

  def coverage_note(partial_tasks, _, _) when is_integer(partial_tasks), do: nil

  defp reasons(summary, liveness) do
    []
    |> add_reason(:running, liveness == :running)
    |> add_reason(:no_usage, int(summary, :unmetered_rows) > 0)
    |> add_reason(:unpriced, int(summary, :unpriced_rows) > 0)
  end

  defp add_reason(reasons, reason, true), do: reasons ++ [reason]
  defp add_reason(reasons, _reason, false), do: reasons

  defp divide(%__MODULE__{} = receipt, per) when is_integer(per) and per > 0 do
    %{receipt | lower_bound_usd: receipt.lower_bound_usd / per}
  end

  defp divide(receipt, _per), do: receipt

  defp format(%__MODULE__{state: :empty}, :badge) do
    %{text: "", title: "No usage recorded.", tone: :empty, show?: false}
  end

  defp format(%__MODULE__{state: :empty}, variant) when variant in [:detail, :markdown] do
    %{text: "no usage recorded", title: "No usage recorded.", tone: :empty, show?: true}
  end

  defp format(%__MODULE__{state: :measured} = receipt, _variant) do
    money = format_usd(receipt.lower_bound_usd)
    %{text: money, title: "Measured spend is #{money}.", tone: :measured, show?: true}
  end

  defp format(%__MODULE__{state: :estimated} = receipt, _variant) do
    money = format_usd(receipt.lower_bound_usd)
    text = "est. #{money}"
    %{text: text, title: "Estimated spend is #{money}.", tone: :estimated, show?: true}
  end

  defp format(%__MODULE__{state: :partial} = receipt, _variant) do
    money = partial_money(receipt)
    reason = reason_text(receipt.reasons)
    text = "≥ #{money} · #{reason}"

    %{
      text: text,
      title: "Lower bound is #{money}. #{reason}.",
      tone: :partial,
      show?: true
    }
  end

  defp partial_money(%__MODULE__{basis: :estimated, lower_bound_usd: usd}) when usd > 0 do
    "est. #{format_usd(usd)}"
  end

  defp partial_money(%__MODULE__{lower_bound_usd: usd}), do: format_usd(usd)

  defp reason_text(reasons) do
    Enum.map_join(reasons, ", ", &Map.fetch!(@reason_text, &1))
  end

  defp phrase(1, singular, _plural), do: "1 #{singular}"
  defp phrase(n, _singular, plural), do: "#{n} #{plural}"

  defp format_usd(amount) when is_number(amount) do
    amount = amount * 1.0
    rounded = Float.round(amount, 4)

    shown = if(rounded == 0.0 and amount > 0.0, do: first_nonzero(amount), else: rounded)

    "$#{trim_decimals(shown)}"
  end

  defp first_nonzero(amount) do
    Enum.find_value(5..12, amount, fn places ->
      rounded = Float.round(amount, places)
      if rounded > 0.0, do: rounded
    end)
  end

  defp trim_decimals(amount) do
    negative? = amount < 0
    places = decimal_places(abs(amount))
    text = :erlang.float_to_binary(abs(amount) * 1.0, decimals: places)
    [whole, frac] = String.split(text, ".")
    frac = frac |> String.trim_trailing("0") |> pad_frac()
    sign = if negative?, do: "-", else: ""
    sign <> whole <> "." <> frac
  end

  defp decimal_places(amount) do
    rounded4 = Float.round(amount, 4)

    if rounded4 == 0.0 and amount > 0.0 do
      Enum.find(5..12, 12, &(Float.round(amount, &1) > 0.0))
    else
      4
    end
  end

  defp pad_frac(frac) when byte_size(frac) >= 2, do: frac
  defp pad_frac(frac), do: String.pad_trailing(frac, 2, "0")

  defp int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 -> n
      n when is_float(n) and n >= 0 -> trunc(n)
      _ -> 0
    end
  end

  defp float(map, key) do
    case Map.get(map, key) do
      n when is_number(n) -> n * 1.0
      _ -> 0.0
    end
  end
end
