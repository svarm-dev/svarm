defmodule Svarm.Workflow do
  @moduledoc """
  Repo-owned `WORKFLOW.md` (Symphony spec §5): YAML front matter + prompt body.
  """

  @type t :: %__MODULE__{
          config: map(),
          prompt_template: String.t(),
          path: String.t()
        }

  defstruct [:config, :prompt_template, :path]

  @front_matter_re ~r/\A---\r?\n([\s\S]*?)\r?\n---\r?\n([\s\S]*)\z/

  @doc """
  Load and parse `WORKFLOW.md`. Returns `{:ok, %Workflow{}}` or `{:error, reason}`.
  """
  def load(path) do
    with {:ok, contents} <- File.read(path) do
      parse(contents, path)
    end
  end

  @doc false
  def parse(contents, path \\ "WORKFLOW.md") when is_binary(contents) do
    case Regex.run(@front_matter_re, contents) do
      [_, yaml, body] ->
        with {:ok, config} <- YamlElixir.read_from_string(yaml) do
          {:ok,
           %__MODULE__{
             config: config || %{},
             prompt_template: String.trim(body),
             path: path
           }}
        end

      nil ->
        {:error, :missing_front_matter}
    end
  end

  @doc "Symphony §5.1 precedence: explicit path, then cwd WORKFLOW.md, then priv template."
  def discover(opts \\ []) do
    candidates =
      [
        System.get_env("SVARM_WORKFLOW_PATH"),
        Keyword.get(opts, :path),
        Path.join(File.cwd!(), "WORKFLOW.md"),
        Path.join(:code.priv_dir(:svarm), "workflow_template.md")
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))

    Enum.reduce_while(candidates, {:error, :workflow_not_found}, &try_load/2)
  end

  defp try_load(path, _acc) do
    if File.regular?(path) do
      case load(path) do
        {:ok, _} = ok -> {:halt, ok}
        err -> {:cont, err}
      end
    else
      {:cont, {:error, :workflow_not_found}}
    end
  end
end
