defmodule Svarm.Provider.OpenRouter do
  @moduledoc """
  OpenRouter provider adapter. Same OpenAI-compatible HTTP path as
  `Svarm.Provider.OpenAICompat`, plus OpenRouter attribution headers.

  Configuration in priv/providers.toml:
    [provider.openrouter]
    adapter = "openrouter"
    auth_env = "OPENROUTER_API_KEY"
    base_url = "https://openrouter.ai/api/v1"
    default_model = "openrouter/free"
  """
  @behaviour Svarm.Provider

  alias Svarm.Provider.{OpenAICompat, Resolve}

  @impl true
  def complete(model, messages, opts \\ []) do
    OpenAICompat.complete(model, messages, with_openrouter(opts))
  end

  @impl true
  def list_models(opts \\ []) do
    OpenAICompat.list_models(with_openrouter(opts))
  end

  @impl true
  def default_model do
    case Resolve.entry("openrouter") do
      %{default_model: model} when is_binary(model) and model != "" -> model
      _ -> "openrouter/free"
    end
  end

  defp with_openrouter(opts) do
    opts
    |> Keyword.put_new(:extra_headers, openrouter_headers())
    |> put_openrouter_config()
  end

  defp put_openrouter_config(opts) do
    case Keyword.get(opts, :config) do
      %{id: _} ->
        opts

      _ ->
        case Resolve.resolve("openrouter") do
          {:ok, {_mod, config}} -> Keyword.put(opts, :config, config)
          {:error, _} -> opts
        end
    end
  end

  defp openrouter_headers do
    [
      "http-referer": "https://svarm.dev",
      "x-openrouter-title": "Svarm"
    ]
  end
end
