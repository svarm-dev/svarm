defmodule Svarm.Redact do
  @moduledoc false
  # Scrub secrets before inspect/logs. Runtime code still holds plaintext in memory.

  @secret_atoms ~w(api_key private_key token authorization password secret access_token)a
  @secret_strings ~w(api_key private_key token authorization password secret access_token)

  # Env-style KEY=value dumps (printenv / export / agent tool output).
  # Matches bare secret names and common suffixes (*_PASSWORD, *_API_KEY, …).
  # Does not match PATH, HOME, NODE_ENV, and other non-secret env vars.
  @env_names ~r/\b((?:[A-Z][A-Z0-9_]*_)?(?:API_KEY|SECRET_ACCESS_KEY|ACCESS_KEY|PRIVATE_KEY|PASSWORD|SECRET|TOKEN)|SECRET_KEY_BASE)=([^\s\n"']+)/

  # Provider / PAT token shapes (OpenAI, Anthropic, OpenRouter, GitHub, GitLab, Slack, npm, PyPI, Stripe).
  # Longer / more specific prefixes first; generic `sk-` requires 20+ body chars to limit false positives.
  @token_shapes ~r/\b(?:sk-or-v1-[A-Za-z0-9_\-]{8,}|sk-ant-[A-Za-z0-9_\-]{8,}|sk-proj-[A-Za-z0-9_\-]{8,}|sk-[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{8,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|ghu_[A-Za-z0-9]{20,}|ghs_[A-Za-z0-9]{20,}|ghr_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_\-]{8,}|xox[bpas]-[A-Za-z0-9\-]{10,}|npm_[A-Za-z0-9]{20,}|pypi-[A-Za-z0-9_\-]{20,}|sk_live_[A-Za-z0-9]{10,}|sk_test_[A-Za-z0-9]{10,}|rk_live_[A-Za-z0-9]{10,}|rk_test_[A-Za-z0-9]{10,})/

  # Standalone Bearer credentials (HTTP headers, curl -H, agent prose).
  # Min 8 credential chars so "Bearer alone" / short words are left alone.
  @bearer ~r/\bBearer\s+[A-Za-z0-9\-._~+\/]{8,}=*/i

  # Full Authorization header values (Bearer, Basic, raw tokens) through end of line.
  @authorization ~r/(\bAuthorization:\s*)([^\n\r]+)/i

  # PEM private key blocks (RSA, EC, OPENSSH, PKCS#8, encrypted). Public keys are not matched.
  @pem_block ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----/

  @doc "Deep-redact maps and lists (nested MCP content arrays included). Other terms as-is."
  def map(data) when is_map(data) do
    Map.new(data, fn {k, v} ->
      if secret_key?(k) do
        {k, redact_value(v)}
      else
        {k, map(v)}
      end
    end)
  end

  def map(data) when is_list(data), do: Enum.map(data, &map/1)
  def map(data) when is_binary(data), do: text(data)
  def map(other), do: other

  @doc "Redact secrets in free-form log text (agent tool output, env dumps)."
  def text(s) when is_binary(s) do
    s
    |> then(&Regex.replace(@pem_block, &1, "[redacted pem]"))
    |> then(&Regex.replace(@env_names, &1, "\\1=[redacted]"))
    |> then(&Regex.replace(@authorization, &1, "\\1[redacted]"))
    |> then(&Regex.replace(@bearer, &1, "Bearer [redacted]"))
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
