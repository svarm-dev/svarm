defmodule Svarm.Workflow.Render do
  @moduledoc "Liquid-ish `{{issue.*}}` / `{{attempt}}` substitution for workflow prompt body."

  @doc """
  Render `prompt_template` with `issue` (kanban task) and `attempt` (integer or nil).
  """
  def render(template, issue, attempt \\ nil) when is_binary(template) do
    case validate_placeholders(template) do
      :ok ->
        m = normalize_issue(issue)
        attempt_str = if attempt in [nil, 0], do: "", else: Integer.to_string(attempt)

        rendered =
          template
          |> String.replace("{{attempt}}", attempt_str)
          |> String.replace("{{issue.id}}", m.id)
          |> String.replace("{{issue.title}}", m.title)
          |> String.replace("{{issue.description}}", m.description)
          |> String.replace("{{issue.body}}", m.body)
          |> String.replace("{{issue.status}}", m.status)
          |> String.replace("{{issue.assignee}}", m.assignee)

        {:ok, rendered}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Validate that the template only uses known placeholders.
  Returns :ok or {:error, {:unknown_placeholders, [unknown_var]}}.
  Per Symphony §5.4: unknown {{vars}} must fail, no silent passthrough.
  """
  def validate(template) when is_binary(template) do
    validate_placeholders(template)
  end

  def validate(_), do: :ok

  defp validate_placeholders(template) do
    placeholders =
      Regex.scan(~r/\{\{\s*([^}|]+?)(?:\s*\|[^}]*)?\s*\}\}/, template, capture: :all_but_first)
      |> Enum.map(fn [inner] ->
        inner |> String.trim() |> then(&String.split(&1, "|", parts: 2)) |> hd() |> String.trim()
      end)
      |> Enum.uniq()

    allowed = [
      "attempt",
      "issue.id",
      "issue.title",
      "issue.description",
      "issue.body",
      "issue.status",
      "issue.assignee"
    ]

    unknown = Enum.filter(placeholders, fn p -> p not in allowed end)

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_placeholders, unknown}}
    end
  end

  @doc "Default prompt template (fallback when no WORKFLOW.md body)."
  def default_template do
    """
    You are an autonomous engineer working on task {{issue.id}}.

    Title: {{issue.title}}

    Description:
    {{issue.description}}

    Work entirely within the current working directory (an isolated workspace).
    Implement on a new branch, run tests/lint if present (fail → exit non-zero),
    open a pull request, summarize what you verified, then stop.
    Do not merge and do not push to main/master.
    """
    |> String.trim()
  end

  defp normalize_issue(issue) do
    %{
      id: field(issue, :id),
      title: field(issue, :title),
      body: field(issue, :body),
      description: field(issue, :description) || field(issue, :body),
      status: field(issue, :status),
      assignee: field(issue, :assignee)
    }
    |> Map.update!(:description, &(&1 || ""))
    |> Map.update!(:body, &(&1 || ""))
    |> Map.update!(:title, &(&1 || ""))
    |> Map.update!(:id, &(&1 || ""))
    |> Map.update!(:status, &(&1 || ""))
    |> Map.update!(:assignee, &(&1 || ""))
    |> then(fn m ->
      %{
        id: to_string(m.id),
        title: to_string(m.title),
        body: to_string(m.body),
        description: to_string(m.description),
        status: to_string(m.status),
        assignee: to_string(m.assignee)
      }
    end)
  end

  defp field(issue, key) do
    map =
      case issue do
        %_{} = s -> Map.from_struct(s)
        m when is_map(m) -> m
      end

    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  @doc """
  Resolve the prompt template (from WORKFLOW.md or default) and render it
  for the given task + attempt. Shared by runners.
  """
  def render_prompt(task, attempt) do
    template =
      case Svarm.Workflow.Store.get() do
        %Svarm.Workflow{prompt_template: t} when is_binary(t) and t != "" -> t
        _ -> default_template()
      end

    render(template, task, attempt)
  end
end
