defmodule Svarm.Provider.OpenAICompat do
  @moduledoc """
  Config-driven OpenAI-compatible chat provider (Req only).

  Used by advertised OpenCode Go/Zen rows for `chat/completions` ids.
  MiniMax/Qwen ids that speak Anthropic `/messages` are routed through
  `Svarm.Provider.AnthropicMessages` (`Resolve.messages_model?/2`). Does
  **not** send OpenRouter `http-referer` / `x-openrouter-title` headers.
  Pass those only from `Svarm.Provider.OpenRouter`.
  """
  @behaviour Svarm.Provider

  require Logger

  alias Svarm.Provider.{AnthropicMessages, HTTP, Resolve}
  alias Svarm.Settings.Resolve, as: KeyResolve

  @impl true
  def complete(model, messages, opts \\ []) do
    with {:ok, config} <- fetch_config(opts),
         {:ok, api_key} <- fetch_key(config) do
      if Resolve.messages_model?(config, model) do
        AnthropicMessages.complete(model, messages, Keyword.put(opts, :config, config))
      else
        post_completion(model, messages, opts, config, api_key)
      end
    end
  end

  @impl true
  def list_models(opts \\ []) do
    with {:ok, config} <- fetch_config(opts),
         {:ok, api_key} <- fetch_key(config) do
      get_models(opts, config, api_key)
    end
  end

  @impl true
  def default_model do
    case fetch_config([]) do
      {:ok, %{default_model: model}} when is_binary(model) and model != "" -> model
      _ -> ""
    end
  end

  @doc false
  def fetch_config(opts) when is_list(opts) do
    case Keyword.get(opts, :config) do
      %{id: _, base_url: _} = config ->
        {:ok, config}

      _ ->
        case Resolve.adapter_and_config(opts) do
          {:ok, {__MODULE__, config}} -> {:ok, config}
          {:ok, _} -> {:error, :unknown_provider}
          {:error, _} = err -> err
        end
    end
  end

  defp fetch_key(config) do
    case KeyResolve.provider_api_key(config.id) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :no_api_key}
    end
  end

  defp post_completion(model, messages, opts, config, api_key) do
    extra_headers = Keyword.get(opts, :extra_headers, [])
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    url = "#{config.base_url}/chat/completions"

    headers =
      [authorization: "Bearer #{api_key}"] ++ extra_headers

    body = %{model: model, messages: messages, max_tokens: max_tokens}

    case req_post(url, json: body, headers: headers, receive_timeout: 120_000, plug: opts[:plug]) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, resp, extract_usage(resp, model, config.id)}

      other ->
        HTTP.handle_error(config.id, other)
    end
  end

  defp get_models(opts, config, api_key) do
    url = "#{config.base_url}/models"
    headers = [authorization: "Bearer #{api_key}"]

    case req_get(url, headers: headers, plug: opts[:plug]) do
      {:ok, %{status: 200, body: resp}} ->
        models =
          (resp["data"] || [])
          |> Enum.map(& &1["id"])
          |> Enum.filter(&Resolve.completable_model?(config, &1))

        {:ok, models}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:error, reason} ->
        Logger.error("#{config.id}: list_models failed #{inspect(reason)}")
        {:error, reason}

      other ->
        HTTP.handle_error(config.id, other)
    end
  end

  defp req_post(url, opts), do: Req.post(url, HTTP.compact_req(opts))
  defp req_get(url, opts), do: Req.get(url, HTTP.compact_req(opts))

  defp extract_usage(resp, model, provider_id) do
    u = resp["usage"] || %{}

    %{
      prompt_tokens: u["prompt_tokens"],
      completion_tokens: u["completion_tokens"],
      model: resp["model"] || model,
      provider: provider_id,
      provider_cost_usd: usage_cost(u)
    }
  end

  defp usage_cost(u) do
    case u["cost"] || u["total_cost"] do
      n when is_number(n) -> n
      _ -> nil
    end
  end
end
