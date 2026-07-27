defmodule Svarm.Runner.LogFormat do
  @moduledoc """
  Pure helpers to turn agent tool payloads into human-readable log lines.

  Adapters (PiRPC, CLI, …) map their event types here; this module does not
  know about ports or PubSub. Content shape matches pi / MCP text blocks.
  """

  @doc """
  Extract human text from a tool partial/result.

  Returns `nil` for empty / no-op payloads (caller should not log).
  """
  def unwrap(nil), do: nil
  def unwrap(""), do: nil

  def unwrap(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      t -> t
    end
  end

  def unwrap(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(&block_text/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  def unwrap(%{"text" => text}) when is_binary(text), do: unwrap(text)

  def unwrap(list) when is_list(list) do
    list
    |> Enum.map(&unwrap/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  def unwrap(_other), do: nil

  @doc "Line for the start of a tool call (optional)."
  def tool_start(name, args \\ nil) when is_binary(name) do
    case args_summary(args) do
      nil -> "\n$ #{name}\n"
      summary -> "\n$ #{name} #{summary}\n"
    end
  end

  @doc "Line for a failed tool; uses unwrap on the result when possible."
  def tool_fail(name, result) when is_binary(name) do
    body = unwrap(result) || "failed"
    "\n[tool #{name} failed]\n#{body}\n"
  end

  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: unwrap(text)
  defp block_text(%{"text" => text}) when is_binary(text), do: unwrap(text)
  defp block_text(text) when is_binary(text), do: unwrap(text)
  defp block_text(_), do: nil

  defp args_summary(nil), do: nil
  defp args_summary(""), do: nil

  defp args_summary(args) when is_binary(args) do
    case String.trim(args) do
      "" -> nil
      s -> String.slice(s, 0, 120)
    end
  end

  defp args_summary(args) when is_map(args) do
    cmd = Map.get(args, "command") || Map.get(args, :command)
    if is_binary(cmd), do: args_summary(cmd), else: nil
  end

  defp args_summary(_), do: nil
end
