defmodule Svarm.Identity do
  @moduledoc """
  Agent naming helpers for external systems (GitHub App slugs, git identity).

  v1 uses a shared Svärm GitHub App; `slugify/1` is ready for per-agent Apps later.
  """

  @doc """
  Derive a GitHub-safe App slug from an operator-chosen agent name.

  Appends `-svarm`. Normalizes Unicode to ASCII-ish lowercase kebab-case.

      iex> Svarm.Identity.slugify("Reece")
      "reece-svarm"

      iex> Svarm.Identity.slugify("Bug Hunter")
      "bug-hunter-svarm"
  """
  def slugify(name) when is_binary(name) do
    base =
      name
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> case do
        "" -> "agent"
        s -> s
      end

    base <> "-svarm"
  end

  def slugify(_), do: "agent-svarm"
end
