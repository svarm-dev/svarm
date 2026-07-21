defmodule Svarm.GitHub.AppAuthTest do
  use ExUnit.Case, async: false

  alias Svarm.GitHub.AppAuth

  setup do
    AppAuth.clear_cache()
    :ok
  end

  describe "token_for_repo/1 PAT mode" do
    test "returns api_key when present" do
      assert {:ok, "ghp_x"} = AppAuth.token_for_repo(%{auth: :token, api_key: "ghp_x"})
    end

    test "defaults to token auth" do
      assert {:ok, "t"} = AppAuth.token_for_repo(%{api_key: "t"})
    end

    test "errors when token missing" do
      assert {:error, :missing_github_token} = AppAuth.token_for_repo(%{auth: :token})
    end
  end

  describe "jwt/2" do
    setup do
      pem_path = System.tmp_dir!() |> Path.join("svarm_app_auth_test.pem")

      unless File.exists?(pem_path) do
        {_, 0} =
          System.cmd("openssl", ["genrsa", "-out", pem_path, "2048"], stderr_to_stdout: true)
      end

      %{pem: File.read!(pem_path)}
    end

    test "builds RS256 JWT with app id as iss", %{pem: pem} do
      assert {:ok, jwt} = AppAuth.jwt("4242", pem)
      [header_b64, payload_b64, sig] = String.split(jwt, ".")
      assert byte_size(sig) > 20

      header =
        payload_b64
        |> then(fn _ -> Base.url_decode64!(header_b64, padding: false) end)
        |> Jason.decode!()

      payload = Base.url_decode64!(payload_b64, padding: false) |> Jason.decode!()

      assert header["alg"] == "RS256"
      assert payload["iss"] == "4242"
      assert is_integer(payload["exp"])
      assert payload["exp"] > payload["iat"]
    end

    test "rejects invalid PEM" do
      assert {:error, :invalid_private_key} = AppAuth.jwt("1", "not-a-key")
    end
  end

  describe "installation_token/1 config errors" do
    test "missing app id" do
      assert {:error, :missing_github_app_id} =
               AppAuth.installation_token(%{auth: :app, private_key: "x"})
    end

    test "missing private key" do
      assert {:error, :missing_github_app_private_key} =
               AppAuth.installation_token(%{auth: :app, app_id: "1"})
    end
  end

  describe "token cache" do
    setup do
      pem_path = System.tmp_dir!() |> Path.join("svarm_app_auth_test.pem")

      unless File.exists?(pem_path) do
        {_, 0} =
          System.cmd("openssl", ["genrsa", "-out", pem_path, "2048"], stderr_to_stdout: true)
      end

      # Bypass real GitHub by pre-seeding cache via mint path isn't possible without HTTP;
      # exercise clear_cache and PAT path only here.
      %{pem: File.read!(pem_path)}
    end

    test "clear_cache is safe when empty" do
      assert :ok = AppAuth.clear_cache()
      assert :ok = AppAuth.clear_cache()
    end
  end
end
