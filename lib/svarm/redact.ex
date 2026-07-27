defmodule Svarm.Redact do
  @moduledoc false
  # Scrub secrets before inspect/logs. Runtime code still holds plaintext in memory.

  @secret_atoms ~w(api_key private_key token authorization password secret access_token)a
  @secret_strings ~w(api_key private_key token authorization password secret access_token)

  # Common env var names agents dump via `env` / `printenv`.
  @env_names ~r/\b(OPENROUTER_API_KEY|OPENAI_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN|GH_TOKEN|SECRET_KEY_BASE|AWS_SECRET_ACCESS_KEY|API_KEY|TOKEN)=([^\s\n"']+)/

  # Token shapes (PAT, OpenRouter, GitHub classic/fine-grained, sk-*).
  @token_shapes ~r/\b(sk-or-v1-|sk-ant-|sk-|github_pat_|ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9_\-]+/

  @doc "Deep-redact known secret keys in maps. Non-maps returned as-is."
  def map(data) when is_map(data) do
    Map.new(data, fn {k, v} ->
      cond do
        secret_key?(k) -> {k, redact_value(v)}
        is_map(v) -> {k, map(v)}
        is_binary(v) -> {k, text(v)}
        true -> {k, v}
      end
    end)
  end

  def map(other), do: other

  @doc "Redact secrets in free-form log text (agent tool output, env dumps)."
  def text(s) when is_binary(s) do
    s
    |> then(&Regex.replace(@env_names, &1, "\\1=[redacted]"))
    |> then(&Regex.replace(@token_shapes, &1, "[redacted]"))
  end

  def text(other), do: other

  defp secret_key?(k) when is_atom(k), do: k in @secret_atoms
  defp secret_key?(k) when is_binary(k), do: k in @secret_strings
  defp secret_key?(_), do: false

  defp redact_value(v) when is_binary(v) and byte_size(v) > 0, do: "[redacted]"
  defp redact_value(v) when is_binary(v), do: v
  defp redact_value(nil), do: nil
  defp redact_value(_), do: "[redacted]"
end
