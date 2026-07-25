defmodule Svarm.Settings.Crypto do
  @moduledoc """
  Encrypts settings secrets with `Plug.Crypto.MessageEncryptor`.

  Keys are derived from the endpoint `secret_key_base`. Rotating
  `SECRET_KEY_BASE` invalidates stored secrets — re-enter them in `/setup`.
  """

  @aad "svarm.settings.v1"

  @doc "Encrypt a UTF-8 plaintext secret. Returns ciphertext binary."
  def encrypt(plaintext) when is_binary(plaintext) do
    {secret, sign_secret} = keys()
    Plug.Crypto.MessageEncryptor.encrypt(plaintext, @aad, secret, sign_secret)
  end

  @doc "Decrypt ciphertext. Returns `{:ok, plaintext}` or `:error`."
  def decrypt(ciphertext) when is_binary(ciphertext) do
    {secret, sign_secret} = keys()
    Plug.Crypto.MessageEncryptor.decrypt(ciphertext, @aad, secret, sign_secret)
  end

  def decrypt(_), do: :error

  defp keys do
    base = secret_key_base()
    secret = Plug.Crypto.KeyGenerator.generate(base, "svarm settings encrypt", length: 32)
    sign_secret = Plug.Crypto.KeyGenerator.generate(base, "svarm settings sign", length: 32)
    {secret, sign_secret}
  end

  defp secret_key_base do
    Application.fetch_env!(:svarm, SvarmWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end
end
