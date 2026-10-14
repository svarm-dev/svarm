defmodule Svarm.Usage.ReceiptTest do
  use ExUnit.Case, async: true

  alias Svarm.Usage.Receipt

  test "measured, estimated, partial, and empty print the receipt strings" do
    measured = summary(1.23, estimated: false, record_count: 1)

    assert Receipt.label(measured, :settled, :badge) == %{
             text: "$1.23",
             title: "Measured spend is $1.23.",
             tone: :measured,
             show?: true
           }

    estimated = summary(0.42, estimated: true, record_count: 1)

    assert Receipt.label(estimated, :settled, :detail).text == "est. $0.42"

    assert Receipt.label(summary(0.0, estimated: true, record_count: 1), :settled, :badge).text ==
             "est. $0.00"

    partial =
      summary(1.23, estimated: false, record_count: 2, unpriced_rows: 1)

    for variant <- [:badge, :detail, :markdown] do
      assert Receipt.label(partial, :settled, variant).text == "≥ $1.23 · unpriced model"
    end

    estimated_partial =
      summary(1.23, estimated: true, record_count: 2, unpriced_rows: 1)

    assert Receipt.label(estimated_partial, :settled, :markdown).text ==
             "≥ est. $1.23 · unpriced model"

    assert Receipt.label(nil, :running, :badge).text == "≥ $0.00 · running"
    assert Receipt.label(nil, :running, :detail).text == "≥ $0.00 · running"

    empty = Receipt.label(nil, :settled, :badge)
    assert empty.show? == false
    refute empty.text =~ "$"

    assert Receipt.label(nil, :settled, :detail).text == "no usage recorded"
    assert Receipt.label(Receipt.empty_summary(), :settled, :markdown).text == "no usage recorded"
    refute Receipt.label(nil, :settled, :markdown).text =~ "$"
  end

  test "money keeps two decimals, keeps a fourth place, and does not hide a positive amount" do
    assert Receipt.label(summary(0.1, record_count: 1), :settled, :badge).text == "$0.10"
    assert Receipt.label(summary(0.0148, record_count: 1), :settled, :badge).text == "$0.0148"
    assert Receipt.label(summary(0.00001, record_count: 1), :settled, :badge).text != "$0.00"
    assert Receipt.label(summary(0.0, record_count: 1), :settled, :badge).text == "$0.00"
  end

  test "reasons stay in order on every variant" do
    summary =
      summary(1.23,
        estimated: false,
        record_count: 3,
        unmetered_rows: 1,
        unpriced_rows: 1
      )

    text = "≥ $1.23 · running, adapter does not report usage, unpriced model"

    for variant <- [:badge, :detail, :markdown] do
      assert Receipt.label(summary, :running, variant).text == text
    end
  end

  test "a running receipt becomes measured when the summary settles" do
    running = summary(0.42, estimated: false, record_count: 1)
    assert Receipt.label(running, :running, :badge).text == "≥ $0.42 · running"

    settled = summary(0.55, estimated: false, record_count: 2)
    label = Receipt.label(settled, :settled, :badge)
    assert label.text == "$0.55"
    refute label.text =~ "running"
  end

  test "partial text never prints a bare dollar, and measured zero still does" do
    for record_count <- 0..2,
        unmetered_rows <- 0..2,
        unpriced_rows <- 0..2,
        estimated <- [false, true],
        liveness <- [:running, :settled],
        variant <- [:badge, :detail, :markdown] do
      summary =
        summary(0.0,
          estimated: estimated,
          record_count: record_count,
          unmetered_rows: unmetered_rows,
          unpriced_rows: unpriced_rows
        )

      label = Receipt.label(summary, liveness, variant)

      case label.tone do
        :partial ->
          refute bare_dollar?(label.text), label.text

        :empty ->
          refute label.text =~ "$"

        tone when tone in [:measured, :estimated] ->
          assert label.text =~ "$0.00"
      end
    end

    assert Receipt.label(summary(0.0, estimated: false, record_count: 1), :settled, :badge).text ==
             "$0.00"

    assert Receipt.label(summary(0.0, estimated: true, record_count: 1), :settled, :badge).text ==
             "est. $0.00"
  end

  test "combine sums counters and ORs estimated" do
    assert Receipt.combine([]) == Receipt.empty_summary()

    combined =
      Receipt.combine([
        summary(1.0, estimated: false, record_count: 1, prompt_tokens: 3),
        summary(0.5, estimated: true, record_count: 2, unmetered_rows: 1, completion_tokens: 4)
      ])

    assert combined.total_cost_usd == 1.5
    assert combined.estimated == true
    assert combined.record_count == 3
    assert combined.unmetered_rows == 1
    assert combined.unpriced_rows == 0
    assert combined.prompt_tokens == 3
    assert combined.completion_tokens == 4
  end

  test "per divides the lower bound and keeps the partial reason" do
    summary = summary(1.0, estimated: false, record_count: 2, unpriced_rows: 1)

    assert Receipt.label(summary, :settled, :badge, per: 2).text == "≥ $0.50 · unpriced model"
  end

  test "coverage note names unmeasured runs in the denominator" do
    assert Receipt.coverage_note(0, 3, 1) == nil

    assert Receipt.coverage_note(2, 3, 1) ==
             "2/3 tasks with ledger activity; denominator includes 1 task with 1 unmeasured run"

    assert Receipt.coverage_note(2, 3, 2) ==
             "2/3 tasks with ledger activity; denominator includes 2 tasks with 2 unmeasured runs"
  end

  defp summary(usd, opts) do
    %{
      total_cost_usd: usd * 1.0,
      estimated: Keyword.get(opts, :estimated, false),
      record_count: Keyword.get(opts, :record_count, 0),
      unmetered_rows: Keyword.get(opts, :unmetered_rows, 0),
      unpriced_rows: Keyword.get(opts, :unpriced_rows, 0),
      prompt_tokens: Keyword.get(opts, :prompt_tokens, 0),
      completion_tokens: Keyword.get(opts, :completion_tokens, 0)
    }
  end

  defp bare_dollar?(text) do
    text
    |> String.split("$")
    |> Enum.drop(-1)
    |> Enum.any?(fn prefix ->
      not (String.ends_with?(prefix, "≥ ") or String.ends_with?(prefix, "≥ est. "))
    end)
  end
end
