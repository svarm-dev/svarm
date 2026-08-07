defmodule Svarm.RedactTest do
  use ExUnit.Case, async: true

  alias Svarm.Redact

  test "map redacts atom and string secret keys" do
    raw =
      %{
        kind: :github,
        api_key: "github_pat_SECRET",
        owner: "svarm-dev"
      }
      |> Map.put("private_key", "-----BEGIN RSA PRIVATE KEY-----")

    out = Redact.map(raw)
    assert out.api_key == "[redacted]"
    assert out["private_key"] == "[redacted]"
    assert out.owner == "svarm-dev"
    assert out.kind == :github
  end

  test "orchestrator inspect never prints tracker api_key" do
    state = %Svarm.Orchestrator{
      tracker_config: %{
        kind: :github,
        api_key: "github_pat_DO_NOT_LOG",
        owner: "svarm-dev",
        repo: "svarm"
      },
      workflow: %Svarm.Workflow{
        path: "/app/config/WORKFLOW.md",
        config: %{"tracker" => %{"api_key" => "github_pat_ALSO_SECRET"}},
        prompt_template: "hi"
      },
      agents: %{}
    }

    text = inspect(state)
    refute text =~ "github_pat_DO_NOT_LOG"
    refute text =~ "github_pat_ALSO_SECRET"
    assert text =~ "redacted"
    assert text =~ "svarm-dev"
  end

  test "text redacts env dumps and token shapes" do
    raw = """
    OPENROUTER_API_KEY=sk-or-v1-SECRETVALUEHERE123
    GITHUB_TOKEN=github_pat_11AAAA_SECRET
    also sk-or-v1-anothersecretvalue999 in prose
    """

    out = Redact.text(raw)
    refute out =~ "SECRETVALUE"
    refute out =~ "github_pat_11AAAA_SECRET"
    refute out =~ "anothersecretvalue"
    assert out =~ "OPENROUTER_API_KEY=[redacted]"
    assert out =~ "GITHUB_TOKEN=[redacted]"
    assert out =~ "[redacted]"
  end

  # --- expanded patterns (issue #78); each pattern has a focused example ---

  test "text redacts password and secret env names beyond the original allowlist" do
    raw = """
    DATABASE_PASSWORD=s3cret-db-pass
    MYSQL_ROOT_PASSWORD=root-s3cret
    REDIS_PASSWORD=redis-s3cret
    SMTP_PASSWORD=smtp-s3cret
    AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
    CLIENT_SECRET=oauth-client-secret-value
    """

    out = Redact.text(raw)
    refute out =~ "s3cret-db-pass"
    refute out =~ "root-s3cret"
    refute out =~ "redis-s3cret"
    refute out =~ "smtp-s3cret"
    refute out =~ "wJalrXUtnFEMI"
    refute out =~ "oauth-client-secret-value"
    assert out =~ "DATABASE_PASSWORD=[redacted]"
    assert out =~ "MYSQL_ROOT_PASSWORD=[redacted]"
    assert out =~ "REDIS_PASSWORD=[redacted]"
    assert out =~ "SMTP_PASSWORD=[redacted]"
    assert out =~ "AWS_SECRET_ACCESS_KEY=[redacted]"
    assert out =~ "CLIENT_SECRET=[redacted]"
  end

  test "text redacts Bearer tokens in headers and prose" do
    raw = """
    Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig
    curl -H "Bearer ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    token is Bearer sk-abcdefghijklmnopqrstuvwxyz012345
    """

    out = Redact.text(raw)
    refute out =~ "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    refute out =~ "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    refute out =~ "sk-abcdefghijklmnopqrstuvwxyz012345"
    assert out =~ "Authorization: [redacted]"
    assert out =~ "Bearer [redacted]"
  end

  test "text redacts Authorization Basic headers" do
    raw = "Authorization: Basic dXNlcjpwYXNzd29yZA==\n"
    out = Redact.text(raw)
    refute out =~ "dXNlcjpwYXNzd29yZA=="
    assert out =~ "Authorization: [redacted]"
  end

  test "text redacts PEM private key blocks" do
    raw = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF6PZGFw6
    example+private/key/material+not+real==
    -----END RSA PRIVATE KEY-----
    and also:
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmU=
    -----END OPENSSH PRIVATE KEY-----
    """

    out = Redact.text(raw)
    refute out =~ "MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn"
    refute out =~ "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU"
    refute out =~ "BEGIN RSA PRIVATE KEY"
    refute out =~ "BEGIN OPENSSH PRIVATE KEY"
    assert out =~ "[redacted pem]"
  end

  test "text redacts additional provider token prefixes" do
    raw = """
    openai sk-abcdefghijklmnopqrstuvwxyz012345
    stripe sk_live_51AbCdEfGhIjKlMnOp
    gitlab glpat-abcdefghijklmnopqrstuv
    slack xoxb-1234567890-abcdefghij
    npm npm_abcdefghijklmnopqrstuvwxyz0123
    """

    out = Redact.text(raw)
    refute out =~ "sk-abcdefghijklmnopqrstuvwxyz012345"
    refute out =~ "sk_live_51AbCdEfGhIjKlMnOp"
    refute out =~ "glpat-abcdefghijklmnopqrstuv"
    refute out =~ "xoxb-1234567890-abcdefghij"
    refute out =~ "npm_abcdefghijklmnopqrstuvwxyz0123"
    assert out =~ "[redacted]"
  end

  test "text preserves normal env vars and code-like samples" do
    raw = """
    PATH=/usr/local/bin:/usr/bin
    HOME=/home/agent
    NODE_ENV=production
    def token(user), do: user.token
    # short sk- id label, not a key
    id = "sk-short"
    # public key blocks are not secrets for redaction purposes
    -----BEGIN PUBLIC KEY-----
    MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAN+example
    -----END PUBLIC KEY-----
    word Bearer alone is fine
    """

    out = Redact.text(raw)
    assert out =~ "PATH=/usr/local/bin:/usr/bin"
    assert out =~ "HOME=/home/agent"
    assert out =~ "NODE_ENV=production"
    assert out =~ "def token(user), do: user.token"
    assert out =~ ~s(id = "sk-short")
    assert out =~ "BEGIN PUBLIC KEY"
    assert out =~ "MFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAN+example"
    assert out =~ "word Bearer alone is fine"
  end
end
