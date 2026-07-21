defmodule Svarm.Provider do
  @moduledoc """
  Behaviour for LLM providers. Resolves model names to provider endpoints
  and sends completion requests. The orchestrator and Decompose depend on this
  behaviour, never on specific providers.
  """
  @doc """
  Send a chat completion request. Returns {:ok, response, usage_map} on success,
  or {:error, reason} on failure. The usage_map contains :prompt_tokens,
  :completion_tokens, :model, and :provider keys for ledger recording.
  """
  @callback complete(
              model :: String.t(),
              messages :: [map()],
              opts :: keyword()
            ) :: {:ok, map(), map()} | {:error, term()}

  @doc """
  Returns the list of available models for this provider.
  """
  @callback list_models(opts :: keyword()) :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Returns the default model for this provider.
  """
  @callback default_model() :: String.t()
end
