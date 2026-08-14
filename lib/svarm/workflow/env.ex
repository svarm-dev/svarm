defmodule Svarm.Workflow.Env do
  @moduledoc """
  Shared env and WORKFLOW front-matter flag helpers for optional resume caps.
  """

  @doc "Read a boolean env var; empty/unset keeps `default`."
  @spec env_bool(String.t(), boolean()) :: boolean()
  def env_bool(key, default) when is_binary(key) do
    case System.get_env(key) do
      nil -> default
      "" -> default
      v -> String.downcase(v) in ~w(1 true yes on)
    end
  end

  @doc "Read a positive integer env var; invalid/unset keeps `default`."
  @spec env_int(String.t(), pos_integer()) :: pos_integer()
  def env_int(key, default) when is_binary(key) do
    case System.get_env(key) do
      nil ->
        default

      "" ->
        default

      v ->
        case Integer.parse(v) do
          {n, ""} when n > 0 -> n
          _ -> default
        end
    end
  end

  @doc "Parse a positive integer from WORKFLOW YAML, or nil."
  @spec parse_int(term()) :: pos_integer() | nil
  def parse_int(nil), do: nil
  def parse_int(n) when is_integer(n) and n > 0, do: n

  def parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  def parse_int(_), do: nil

  @doc "Truthy YAML/env-ish values used in WORKFLOW front matter."
  @spec truthy?(term()) :: boolean()
  def truthy?(true), do: true
  def truthy?(false), do: false
  def truthy?("true"), do: true
  def truthy?("yes"), do: true
  def truthy?("1"), do: true
  def truthy?(_), do: false

  @doc "Drop nil values from a cap map so defaults can fill those keys."
  @spec reject_nil(map()) :: map()
  def reject_nil(map) when is_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
