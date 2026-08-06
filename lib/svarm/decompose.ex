defmodule Svarm.Decompose do
  @moduledoc """
  Goal → tasks. Calls an LLM via the provider registry and parses a JSON array.
  Returns %{tasks: [...], goal: goal}.
  """
  alias Svarm.Provider

  require Logger

  @doc "Decompose a goal into tasks. Pass `mock: true` in opts for deterministic demo output (no LLM)."
  def run(args, opts \\ []) do
    goal = Map.fetch!(args, :goal)
    research = Map.get(args, :research, "")

    if Keyword.get(opts, :mock, false) do
      {:ok, %{tasks: mock_tasks(goal, research), goal: goal}}
    else
      llm_run(goal, research)
    end
  end

  defp llm_run(goal, research) do
    prompt = """
    Goal: #{goal}

    Research context:
    #{research}

    Decompose this into 2-7 concrete, actionable tasks. Each task should be
    specific enough that one agent can complete it independently. Type each as
    code | infra | research | config | docs.

    Priority indicates execution order:
      1 = foundational (research, setup) — must complete first
      2 = implementation (coding, config) — depends on priority 1
      3 = polish (docs, tests) — depends on priority 2

    Return ONLY a JSON array, no other text.
    Do NOT include an assignee field — the orchestrator handles routing.
    [
      {"title": "...", "body": "...", "type": "code|infra|research|config|docs",
       "priority": 1}
    ]
    """

    provider = resolve_provider()
    model = provider.default_model()

    case provider.complete(model, [%{role: "user", content: prompt}]) do
      {:ok, response, usage} ->
        text = extract_text(response)
        tasks = parse_tasks(text)

        # Record decompose usage
        record_decompose_usage(goal, model, usage)

        {:ok, %{tasks: tasks, goal: goal}}

      {:error, reason} ->
        Logger.error("decompose: LLM call failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_provider do
    # Default to OpenRouter. When WORKFLOW.md specifies a different provider,
    # resolve here.
    Provider.OpenRouter
  end

  defp extract_text(response) do
    choices = response["choices"] || []

    case List.first(choices) do
      %{"message" => %{"content" => content}} -> content
      _ -> ""
    end
  end

  defp record_decompose_usage(goal, model, usage) do
    Svarm.Usage.append(
      run_id: "dec_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
      task_id: "decompose",
      tenant: goal,
      source: "decompose",
      provider: to_string(usage[:provider] || :openrouter),
      model_id: to_string(usage[:model] || model),
      prompt_tokens: usage[:prompt_tokens],
      completion_tokens: usage[:completion_tokens],
      estimated: true
    )
  end

  defp mock_tasks(goal, research) do
    snippet =
      goal
      |> String.trim()
      |> then(fn g -> if g == "", do: "sample goal", else: String.slice(g, 0, 80) end)

    research_note =
      if research != "" and String.trim(research) != "" do
        "Context: #{String.slice(String.trim(research), 0, 120)}"
      else
        "No extra research supplied (demo mode)."
      end

    [
      demo_task(
        "Demo: clarify scope for #{snippet}",
        "#{research_note}\n\nList acceptance criteria and out-of-scope items.",
        "research",
        1,
        "demo_research"
      ),
      demo_task(
        "Demo: implement core change",
        "demo stub — orchestrator runs staged agent CLI for this task.",
        "code",
        2,
        "demo_code"
      ),
      demo_task(
        "Demo: verify and document",
        "demo — document pass after implementation.",
        "docs",
        3,
        "demo_docs"
      )
    ]
  end

  defp demo_task(title, body, type, priority, assignee) do
    %{title: title, body: body, type: type, priority: priority, assignee: assignee}
  end

  defp parse_tasks(content) do
    json =
      case Regex.run(~r/```(?:json)?\s*(\[.*?\])\s*```/s, content) do
        [_, json_str] -> json_str
        nil -> String.trim(content)
      end

    case Jason.decode(json) do
      {:ok, tasks} when is_list(tasks) ->
        Enum.map(tasks, fn t ->
          %{
            title: Map.get(t, "title", "Untitled"),
            body: Map.get(t, "body", ""),
            type: Map.get(t, "type", "code"),
            priority: Map.get(t, "priority", 0)
          }
        end)

      _ ->
        []
    end
  end
end
