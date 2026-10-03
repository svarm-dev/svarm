defmodule Svarm.Provider.AnthropicMessages do
  @moduledoc """
  Anthropic Messages `/messages` adapter (Req only).

  Used for OpenCode Go/Zen model ids that do not speak OpenAI
  `chat/completions` (Go MiniMax/Qwen; some Zen Qwen). Route selection lives
  in `Svarm.Provider.Resolve`. Auth is `x-api-key` plus `anthropic-version`.
  """
  @behaviour Svarm.Provider

  alias Svarm.Provider.{HTTP, OpenAICompat, Resolve}
  alias Svarm.Settings.Resolve, as: KeyResolve

  @anthropic_version "2023-06-01"

  @impl true
  def complete(model, messages, opts \\ []) do
    with {:ok, config} <- fetch_config(opts),
         {:ok, api_key} <- fetch_key(config) do
      post_messages(model, messages, opts, config, api_key)
    end
  end

  @impl true
  def list_models(opts \\ []), do: OpenAICompat.list_models(opts)

  @impl true
  def default_model, do: OpenAICompat.default_model()

  defp fetch_config(opts) when is_list(opts) do
    case Keyword.get(opts, :config) do
      %{id: _, base_url: _} = config ->
        {:ok, config}

      _ ->
        case Resolve.adapter_and_config(opts) do
          {:ok, {_mod, config}} -> {:ok, config}
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

  defp post_messages(model, messages, opts, config, api_key) do
    extra_headers = Keyword.get(opts, :extra_headers, [])
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    url = "#{config.base_url}/messages"
    {system, chat} = split_system(messages)

    headers =
      [
        "x-api-key": api_key,
        "anthropic-version": @anthropic_version
      ] ++ extra_headers

    body =
      %{model: model, max_tokens: max_tokens, messages: Enum.map(chat, &normalize_message/1)}
      |> maybe_put_system(system)

    case req_post(url, json: body, headers: headers, receive_timeout: 120_000, plug: opts[:plug]) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, normalize_response(resp, model), extract_usage(resp, model, config.id)}

      other ->
        HTTP.handle_error(config.id, other)
    end
  end

  defp split_system(messages) when is_list(messages) do
    {system, rest} = Enum.split_with(messages, &(role(&1) == "system"))
    {Enum.map_join(system, "\n\n", &content_text/1), rest}
  end

  defp maybe_put_system(body, system) when is_binary(system) and system != "" do
    Map.put(body, :system, system)
  end

  defp maybe_put_system(body, _), do: body

  defp normalize_message(msg) do
    %{role: role(msg), content: content_text(msg)}
  end

  defp role(msg) when is_map(msg) do
    to_string(Map.get(stringify(msg), "role", "user"))
  end

  defp content_text(msg) when is_map(msg) do
    case Map.get(stringify(msg), "content") do
      s when is_binary(s) -> s
      list when is_list(list) -> Enum.map_join(list, &block_text/1)
      other -> to_string(other)
    end
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp block_text(block) when is_map(block) do
    case Map.get(stringify(block), "text") do
      t when is_binary(t) -> t
      _ -> ""
    end
  end

  defp block_text(t) when is_binary(t), do: t
  defp block_text(_), do: ""

  defp normalize_response(resp, model) when is_map(resp) do
    text = assistant_text(resp)

    Map.merge(resp, %{
      "model" => resp["model"] || model,
      "choices" => [%{"message" => %{"role" => "assistant", "content" => text}}]
    })
  end

  defp assistant_text(resp) do
    case resp["content"] do
      text when is_binary(text) -> text
      list when is_list(list) -> Enum.map_join(list, &block_text/1)
      _ -> ""
    end
  end

  defp extract_usage(resp, model, provider_id) do
    u = resp["usage"] || %{}

    %{
      prompt_tokens: u["input_tokens"] || u["prompt_tokens"],
      completion_tokens: u["output_tokens"] || u["completion_tokens"],
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

  defp req_post(url, opts), do: Req.post(url, HTTP.compact_req(opts))
end
