defmodule Svarm.Test.GitHubListErrorReq do
  @moduledoc false
  # Stub GitHub issues HTTP as 403 so board/dashboard tests can drive
  # `list_issues` failure without hitting the network.

  def get(_url, _opts), do: {:ok, %{status: 403, headers: %{}}}

  def install do
    previous_req = Application.get_env(:svarm, :github_req)
    Application.put_env(:svarm, :github_req, __MODULE__)

    {:ok, _} =
      Svarm.Settings.put_tracker(%{
        "kind" => "github",
        "owner" => "acme",
        "repo" => "widgets",
        "api_key" => "ghp_test",
        "auth" => "token"
      })

    ExUnit.Callbacks.on_exit(fn ->
      Svarm.Settings.Store.delete("tracker")

      if previous_req do
        Application.put_env(:svarm, :github_req, previous_req)
      else
        Application.delete_env(:svarm, :github_req)
      end
    end)
  end
end
