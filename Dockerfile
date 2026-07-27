# Svärm — multi-stage Docker build
# Elixir 1.20.2 on Erlang/OTP 29

FROM hexpm/elixir:1.20.2-erlang-29.0.3-debian-bookworm-20260713-slim AS builder

WORKDIR /app

# Install hex + rebar, then dependencies
RUN mix local.hex --force && mix local.rebar --force

# Git needed for hex deps (heroicons is a git dep)
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get

# Copy source and compile
COPY lib lib
COPY priv priv
RUN mix compile

# Build assets (Tailwind + esbuild)
COPY assets assets
RUN mix assets.deploy

# Build release
RUN MIX_ENV=prod mix release svarm

# --- Runtime stage ---
FROM node:22-bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssl ca-certificates curl git procps \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (needed for gh repo clone, gh auth, etc.)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the release from builder
COPY --from=builder /app/_build/prod/rel/svarm/ ./

# Templates for first-boot config (entrypoint copies into mounted /app/config)
COPY --from=builder /app/priv/workflow_template.md /app/templates/WORKFLOW.md
COPY --from=builder /app/priv/agents.toml /app/templates/agents.toml
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Runtime configuration
ENV PHX_SERVER=true
ENV MIX_ENV=prod
ENV PORT=4000
ENV HOME=/app
ENV RELEASE_TMP=/app/tmp
ENV SVARM_CONFIG_DIR=/app/config
ENV SVARM_TEMPLATES_DIR=/app/templates

# Install pi so agents can be spawned inside the container
RUN curl -fsSL https://pi.dev/install.sh | sh

# Create data, config, and tmp directories for SQLite and BEAM
RUN mkdir -p /app/data /app/tmp /app/config
VOLUME /app/data
VOLUME /app/config

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["bin/svarm", "start"]
