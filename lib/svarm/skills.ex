defmodule Svarm.Skills do
  @moduledoc """
  Materialize configured agent skill packs into a task workspace at dispatch.

  Operators list filesystem paths on each agent (`skills` in `agents.toml` /
  Settings). Relative paths resolve from the host process CWD (where Svärm was
  started). Each path must exist and be either:

  - a **pack directory** containing `SKILL.md`, or
  - a **`SKILL.md` file** (or any `.md` treated as skill body)

  Packs are copied under `.agents/skills/<name>/` inside the ticket workspace so
  both Pi project discovery and CLI agents see the same layout. Missing or
  invalid packs **fail closed** — no silent skip.

  See [docs/agents.md](../../docs/agents.md).
  """

  @skills_rel Path.join([".agents", "skills"])

  @type injected :: %{
          name: String.t(),
          source: String.t(),
          dest: String.t(),
          relative: String.t()
        }

  @type error ::
          {:skills, :missing, String.t(), String.t()}
          | {:skills, :no_skill_md, String.t(), String.t()}
          | {:skills, :invalid_pack, String.t(), String.t()}
          | {:skills, :duplicate_name, String.t(), String.t()}
          | {:skills, :copy_failed, String.t(), String.t(), term()}

  @doc """
  Copy configured skill packs into `workspace_path/.agents/skills/`.

  Returns `{:ok, injected}` (possibly empty) or `{:error, reason}`.
  `skills` may be `nil` or a list of path strings (non-strings are ignored).
  """
  @spec inject([String.t()] | nil, String.t()) :: {:ok, [injected()]} | {:error, error()}
  def inject(skills, workspace_path)
      when (is_list(skills) or is_nil(skills)) and is_binary(workspace_path) do
    paths = normalize_paths(skills)

    case paths do
      [] ->
        {:ok, []}

      _ ->
        dest_root = skills_root(workspace_path)
        File.mkdir_p!(dest_root)
        inject_all(paths, dest_root)
    end
  end

  def inject(_skills, _workspace_path), do: {:error, {:skills, :invalid_pack, "", ""}}

  @doc "Absolute path to the skills directory inside a workspace."
  @spec skills_root(String.t()) :: String.t()
  def skills_root(workspace_path) when is_binary(workspace_path) do
    Path.join(workspace_path, @skills_rel)
  end

  @doc """
  Append a short prompt section listing injected packs so CLI agents (and models
  that miss progressive disclosure) still see the paths.
  """
  @spec append_prompt_section(String.t(), [injected()]) :: String.t()
  def append_prompt_section(prompt, []) when is_binary(prompt), do: prompt

  def append_prompt_section(prompt, injected) when is_binary(prompt) and is_list(injected) do
    lines =
      Enum.map(injected, fn %{name: name, relative: rel} ->
        "- `#{name}` — read `#{Path.join(rel, "SKILL.md")}` when the task matches"
      end)

    section =
      [
        "## Attached skill packs",
        "Operator-configured skill packs are available under `.agents/skills/` in this workspace.",
        "Load the matching SKILL.md before acting when a pack applies."
      ] ++
        lines

    IO.iodata_to_binary([prompt, "\n\n", Enum.intersperse(section, "\n")])
  end

  @doc "True when `reason` is a skills inject error tuple."
  @spec error?(term()) :: boolean()
  def error?(reason) when is_tuple(reason) and tuple_size(reason) >= 1,
    do: elem(reason, 0) == :skills

  def error?(_), do: false

  @doc "Human-readable error for logs and board lines."
  @spec format_error(error() | term()) :: String.t()
  def format_error({:skills, :missing, raw, abs}),
    do: "skill pack missing: #{raw} (resolved #{abs})"

  def format_error({:skills, :no_skill_md, raw, abs}),
    do: "skill pack has no SKILL.md: #{raw} (resolved #{abs})"

  def format_error({:skills, :invalid_pack, raw, abs}),
    do: "skill pack invalid: #{raw} (resolved #{abs})"

  def format_error({:skills, :duplicate_name, name, raw}),
    do: "skill pack name conflict: #{name} (from #{raw})"

  def format_error({:skills, :copy_failed, raw, abs, reason}),
    do: "skill pack copy failed: #{raw} (resolved #{abs}): #{inspect(reason)}"

  def format_error(other), do: "skill pack error: #{inspect(other)}"

  # -- private --

  defp normalize_paths(nil), do: []

  defp normalize_paths(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&String.trim/1)
  end

  defp inject_all(paths, dest_root) do
    Enum.reduce_while(paths, {:ok, []}, &reduce_inject(&1, &2, dest_root))
  end

  defp reduce_inject(raw, {:ok, acc}, dest_root) do
    case inject_one(raw, dest_root, acc) do
      {:ok, info} -> {:cont, {:ok, acc ++ [info]}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp inject_one(raw, dest_root, already) do
    abs = Path.expand(raw)

    cond do
      not File.exists?(abs) ->
        {:error, {:skills, :missing, raw, abs}}

      File.regular?(abs) ->
        inject_file(raw, abs, dest_root, already)

      File.dir?(abs) ->
        inject_dir(raw, abs, dest_root, already)

      true ->
        {:error, {:skills, :invalid_pack, raw, abs}}
    end
  end

  defp inject_file(raw, abs, dest_root, already) do
    if Path.extname(abs) != ".md" do
      {:error, {:skills, :invalid_pack, raw, abs}}
    else
      materialize_file(raw, abs, dest_root, already)
    end
  end

  defp materialize_file(raw, abs, dest_root, already) do
    name = file_skill_name(abs)

    with :ok <- check_unique(name, raw, already),
         dest = Path.join(dest_root, name),
         :ok <- clear_dest(dest),
         :ok <- mkdir_or_error(dest, raw, abs),
         :ok <- copy_file(abs, Path.join(dest, "SKILL.md"), raw, abs) do
      {:ok, info(name, abs, dest)}
    end
  end

  defp inject_dir(raw, abs, dest_root, already) do
    skill_md = Path.join(abs, "SKILL.md")

    if File.regular?(skill_md) do
      materialize_dir(raw, abs, dest_root, already)
    else
      {:error, {:skills, :no_skill_md, raw, abs}}
    end
  end

  defp materialize_dir(raw, abs, dest_root, already) do
    name = skill_name(Path.basename(abs))

    with :ok <- check_unique(name, raw, already),
         dest = Path.join(dest_root, name),
         :ok <- clear_dest(dest),
         :ok <- copy_tree(abs, dest, raw, abs) do
      {:ok, info(name, abs, dest)}
    end
  end

  defp file_skill_name(abs) do
    if String.downcase(Path.basename(abs)) == "skill.md" do
      abs |> Path.dirname() |> Path.basename() |> skill_name()
    else
      abs |> Path.basename() |> Path.rootname() |> skill_name()
    end
  end

  defp check_unique(name, raw, already) do
    if Enum.any?(already, &(&1.name == name)) do
      {:error, {:skills, :duplicate_name, name, raw}}
    else
      :ok
    end
  end

  defp clear_dest(dest) do
    case File.rm_rf(dest) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, {:skills, :copy_failed, dest, dest, reason}}
    end
  end

  defp mkdir_or_error(dest, raw, abs) do
    case File.mkdir_p(dest) do
      :ok -> :ok
      {:error, reason} -> {:error, {:skills, :copy_failed, raw, abs, reason}}
    end
  end

  defp copy_file(from, to, raw, abs) do
    case File.cp(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:skills, :copy_failed, raw, abs, reason}}
    end
  end

  defp copy_tree(from, to, raw, abs) do
    case File.cp_r(from, to) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, {:skills, :copy_failed, raw, abs, reason}}
    end
  end

  defp info(name, source, dest) do
    %{
      name: name,
      source: source,
      dest: dest,
      relative: Path.join(@skills_rel, name)
    }
  end

  defp skill_name(raw) when is_binary(raw) do
    raw
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unnamed"
      other -> other
    end
  end
end
