defmodule Svarm.Redact do
  @moduledoc false
  # Scrub secrets before inspect/logs. Runtime code still holds plaintext in memory.

  @secret_atoms ~w(api_key private_key token authorization password secret access_token)a
  @secret_strings ~w(api_key private_key token authorization password secret access_token)

  @doc "Deep-redact known secret keys in maps. Non-maps returned as-is."
  def map(data) when is_map(data) do
    Map.new(data, fn {k, v} ->
      cond do
        secret_key?(k) -> {k, redact_value(v)}
        is_map(v) -> {k, map(v)}
        true -> {k, v}
      end
    end)
  end

  def map(other), do: other

  defp secret_key?(k) when is_atom(k), do: k in @secret_atoms
  defp secret_key?(k) when is_binary(k), do: k in @secret_strings
  defp secret_key?(_), do: false

  defp redact_value(v) when is_binary(v) and byte_size(v) > 0, do: "[redacted]"
  defp redact_value(v) when is_binary(v), do: v
  defp redact_value(nil), do: nil
  defp redact_value(_), do: "[redacted]"
end
