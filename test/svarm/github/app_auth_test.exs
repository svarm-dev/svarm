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
      %{pem: test_pem()}
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
      %{pem: test_pem()}
    end

    test "clear_cache is safe when empty" do
      assert :ok = AppAuth.clear_cache()
      assert :ok = AppAuth.clear_cache()
    end

    test "returns unexpired cached installation token", %{pem: pem} do
      expires_at = System.system_time(:millisecond) + 3_600_000
      assert :ok = AppAuth.put_cached_token("99", "ghs_cached", expires_at)

      config = %{auth: :app, app_id: "1", private_key: pem, installation_id: "99"}
      assert {:ok, "ghs_cached"} = AppAuth.installation_token(config)
      assert {:ok, "ghs_cached"} = AppAuth.token_for_repo(config)
    end

    test "injects cached token as GITHUB_TOKEN without minting", %{pem: pem} do
      expires_at = System.system_time(:millisecond) + 3_600_000
      assert :ok = AppAuth.put_cached_token("1", "ghs_bot", expires_at)

      env =
        Svarm.Runner.with_github_token(%{"FOO" => "bar"}, %{
          auth: :app,
          app_id: "1",
          private_key: pem,
          installation_id: "1"
        })

      assert env["GITHUB_TOKEN"] == "ghs_bot"
      assert env["GH_TOKEN"] == "ghs_bot"
      assert env["FOO"] == "bar"
    end

    test "does not store tokens in a public or protected ETS table" do
      expires_at = System.system_time(:millisecond) + 3_600_000
      assert :ok = AppAuth.put_cached_token("7", "ghs_secret", expires_at)

      protection =
        case :ets.whereis(:svarm_github_app_tokens) do
          :undefined -> :none
          tid -> :ets.info(tid, :protection)
        end

      refute protection in [:public, :protected]
    end

    test "other processes cannot ets:lookup cached tokens" do
      expires_at = System.system_time(:millisecond) + 3_600_000
      assert :ok = AppAuth.put_cached_token("7", "ghs_secret", expires_at)

      task =
        Task.async(fn ->
          try do
            :ets.lookup(:svarm_github_app_tokens, "7")
          rescue
            ArgumentError -> :inaccessible
          end
        end)

      refute match?([{"7", "ghs_secret", _}], Task.await(task))
    end

    test "sys status reports do not include cached token values" do
      expires_at = System.system_time(:millisecond) + 3_600_000
      secret = "ghs_secret_never_in_status"
      assert :ok = AppAuth.put_cached_token("7", secret, expires_at)

      dumped = :sys.get_status(AppAuth) |> inspect()
      refute dumped =~ secret
      assert dumped =~ "redacted"
    end
  end

  defp test_pem do
    pem_path = System.tmp_dir!() |> Path.join("svarm_app_auth_test.pem")

    unless File.exists?(pem_path) do
      {_, 0} =
        System.cmd("openssl", ["genrsa", "-out", pem_path, "2048"], stderr_to_stdout: true)
    end

    File.read!(pem_path)
  end
end
