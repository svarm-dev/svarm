defmodule Svarm.Provider.HTTP do
  @moduledoc """
  Shared Req helpers for in-app provider adapters.

  Injects `:provider_req_plug` (tests/CI stubs) and maps gateway status
  codes to tagged tuples. Adapters own request bodies and usage parsing.
  """

  require Logger

  @doc false
  def compact_req(opts) do
    opts
    |> Keyword.put(:plug, request_plug(opts))
    |> Keyword.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc false
  def request_plug(opts) do
    Keyword.get(opts, :plug) || Application.get_env(:svarm, :provider_req_plug)
  end

  @doc false
  def handle_error(id, {:ok, %{status: 400} = resp}) do
    error_msg = get_in(resp.body, ["error", "message"]) || "bad request"
    Logger.error("#{id}: #{error_msg}")
    {:error, {:bad_request, error_msg}}
  end

  def handle_error(_id, {:ok, %{status: 401}}), do: {:error, :unauthorized}
  def handle_error(_id, {:ok, %{status: 429}}), do: {:error, :rate_limited}

  def handle_error(id, {:ok, %{status: code}}) when code >= 500 do
    Logger.error("#{id}: API error #{code}")
    {:error, {:server_error, code}}
  end

  def handle_error(id, {:ok, %{status: code} = resp}) do
    error_msg = get_in(resp.body, ["error", "message"]) || "unknown error"
    Logger.error("#{id}: HTTP #{code}: #{error_msg}")
    {:error, {:http_error, code, error_msg}}
  end

  def handle_error(id, {:error, reason}) do
    Logger.error("#{id}: request failed #{inspect(reason)}")
    {:error, {:network_error, reason}}
  end
end
