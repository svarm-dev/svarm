defmodule Svarm.Usage.Rates do
  @moduledoc """
  Versioned model pricing. Rates are keyed by {provider, model_id}.
  When a provider changes pricing, add a new entry — old records
  always recalculate at the rate that was active when they were recorded.

  All rates in USD per 1M tokens.
  """
  @rates %{
    # OpenRouter (via openrouter.ai)
    {"openrouter", "claude-sonnet-4-20250514"} => %{
      prompt: 3.0,
      completion: 15.0
    },
    {"openrouter", "claude-opus-4-20250514"} => %{
      prompt: 15.0,
      completion: 75.0
    },
    {"openrouter", "gpt-4.1"} => %{
      prompt: 2.0,
      completion: 8.0
    },
    {"openrouter", "gpt-5.1"} => %{
      prompt: 1.75,
      completion: 14.0
    },
    "openrouter/free" => %{
      prompt: 0.0,
      completion: 0.0
    },
    {"openrouter", "gemini-2.5-pro"} => %{
      prompt: 1.25,
      completion: 10.0
    },

    # Anthropic direct
    {"anthropic", "claude-sonnet-4-20250514"} => %{
      prompt: 3.0,
      completion: 15.0
    },
    {"anthropic", "claude-opus-4-20250514"} => %{
      prompt: 15.0,
      completion: 75.0
    },

    # OpenAI direct
    {"openai", "gpt-4.1"} => %{
      prompt: 2.0,
      completion: 8.0
    },
    {"openai", "gpt-5.1"} => %{
      prompt: 1.75,
      completion: 14.0
    }
  }

  @doc """
  Calculate cost in USD for the given provider, model, and token counts.
  Returns {:ok, cost} or {:error, :unknown_model}.
  """
  def cost_usd(provider, model_id, prompt_tokens, completion_tokens)
      when is_binary(provider) and is_binary(model_id) do
    key = {provider, model_id}

    case Map.get(@rates, key) do
      nil ->
        {:error, :unknown_model}

      %{prompt: p_rate, completion: c_rate} ->
        p = (prompt_tokens || 0) / 1_000_000 * p_rate
        c = (completion_tokens || 0) / 1_000_000 * c_rate
        {:ok, Float.round(p + c, 6)}
    end
  end

  @doc """
  Returns the rate map for a given provider and model, or nil if unknown.
  """
  def rate_for(provider, model_id) do
    Map.get(@rates, {provider, model_id})
  end

  @doc """
  Lists all known provider/model pairs.
  """
  def known_models do
    Map.keys(@rates)
  end
end
