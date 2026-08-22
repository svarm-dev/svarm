defmodule Svarm.RepoTest do
  use ExUnit.Case, async: true

  test "Repo waits on SQLITE_BUSY and keeps WAL" do
    repo = Application.get_env(:svarm, Svarm.Repo)
    assert repo[:busy_timeout] == 5_000
    assert repo[:journal_mode] == :wal
    assert repo[:pool_size] == 1
  end
end
