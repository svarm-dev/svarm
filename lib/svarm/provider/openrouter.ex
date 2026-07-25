defmodule Svarm.Provider.OpenRouter do
  @moduledoc """
  OpenRouter provider adapter. Implements `Svarm.Provider` behaviour
  using the OpenRouter API via Req + ReqLLM.

  Configuration in priv/providers.toml:
    [provider.openrouter]
    auth_env = "OPENROUTER_API_KEY"
    base_url = "https://openrouter.ai/api/v1"
    default_model = "claude-sonnet-4-20250514"
  """
  @behaviour Svarm.Provider

  require Logger

  @config_file Path.join(:code.priv_dir(:svarm), "providers.toml")

  @impl true
  def complete(model, messages, opts \\ []) do
    api_key = resolve_api_key()

    if is_nil(api_key) do
      Logger.error("openrouter: OPENROUTER_API_KEY not set")
      {:error, :no_api_key}
    else
      do_post_completion(model, messages, opts, api_key)
    end
  end

  defp do_post_completion(model, messages, opts, api_key) do
    extra_headers = Keyword.get(opts, :extra_headers, [])
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    body = %{model: model, messages: messages, max_tokens: max_tokens}
    url = "#{base_url()}/chat/completions"

    headers =
      [
        authorization: "Bearer #{api_key}",
        "http-referer": "https://svarm.dev",
        "x-openrouter-title": "Svarm"
      ] ++ extra_headers

    case Req.post(url, json: body, headers: headers, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: resp}} ->
        usage = extract_usage(resp, model)
        {:ok, resp, usage}

      other ->
        handle_completion_error(other)
    end
  end

  defp handle_completion_error({:ok, %{status: 400} = resp}) do
    error_msg = get_in(resp.body, ["error", "message"]) || "bad request"
    Logger.error("openrouter: #{error_msg}")
    {:error, {:bad_request, error_msg}}
  end

  defp handle_completion_error({:ok, %{status: 401}}), do: {:error, :unauthorized}
  defp handle_completion_error({:ok, %{status: 429}}), do: {:error, :rate_limited}

  defp handle_completion_error({:ok, %{status: code}}) when code >= 500 do
    Logger.error("openrouter: API error #{code}")
    {:error, {:server_error, code}}
  end

  defp handle_completion_error({:ok, %{status: code} = resp}) do
    error_msg = get_in(resp.body, ["error", "message"]) || "unknown error"
    Logger.error("openrouter: HTTP #{code}: #{error_msg}")
    {:error, {:http_error, code, error_msg}}
  end

  defp handle_completion_error({:error, reason}) do
    Logger.error("openrouter: request failed #{inspect(reason)}")
    {:error, {:network_error, reason}}
  end

  @impl true
  def list_models(_opts \\ []) do
    api_key = resolve_api_key()

    if is_nil(api_key) do
      {:error, :no_api_key}
    else
      url = "#{base_url()}/models"
      headers = [authorization: "Bearer #{api_key}"]

      case Req.get(url, headers: headers) do
        {:ok, %{status: 200, body: resp}} ->
          models = Enum.map(resp["data"] || [], & &1["id"])
          {:ok, models}

        {:error, reason} ->
          Logger.error("openrouter: list_models failed #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl true
  def default_model do
    config() |> Map.get("default_model", "claude-sonnet-4-20250514")
  end

  # -- helpers --

  defp resolve_api_key do
    Svarm.Settings.Resolve.openrouter_api_key()
  end

  defp base_url do
    config() |> Map.get("base_url", "https://openrouter.ai/api/v1")
  end

  defp config do
    with {:ok, contents} <- File.read(@config_file),
         {:ok, map} <- Toml.decode(contents) do
      Map.get(map, "provider", %{})
      |> Map.get("openrouter", %{})
    else
      _ -> %{}
    end
  end

  defp extract_usage(resp, model) do
    u = resp["usage"] || %{}

    %{
      prompt_tokens: u["prompt_tokens"],
      completion_tokens: u["completion_tokens"],
      model: resp["model"] || model,
      provider: :openrouter
    }
  end
end
