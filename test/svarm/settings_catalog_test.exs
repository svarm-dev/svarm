defmodule Svarm.SettingsCatalogTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Svarm.Kanban.Task
  alias Svarm.KanbanBridge
  alias Svarm.Orchestrator
  alias Svarm.Repo
  alias Svarm.Settings.Catalog.Store
  alias Svarm.Settings.Resolve
  alias Svarm.Tracker

  @prior_migration 20_261_001_090_000

  setup do
    on_exit(fn -> clear_catalog() end)
    :ok
  end

  test "migration backfill keeps existing task ids and fills board identity" do
    db =
      Path.join(
        System.tmp_dir!(),
        "svarm-catalog-mig-#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn -> File.rm(db) end)

    repo = __MODULE__.MigrationRepo
    Application.put_env(:svarm, repo, database: db, pool_size: 1)
    start_supervised!(repo)

    path = Application.app_dir(:svarm, "priv/repo/migrations")

    {prior, rest} =
      Enum.split_with(migration_modules(path), fn {version, _} -> version <= @prior_migration end)

    assert rest != []
    assert is_list(Ecto.Migrator.run(repo, prior, :up, all: true, log: false))

    Ecto.Adapters.SQL.query!(
      repo,
      "INSERT INTO tasks (id, title, status) VALUES (?, ?, ?)",
      ["legacy-1", "Legacy", "todo"]
    )

    Ecto.Adapters.SQL.query!(
      repo,
      "INSERT INTO run_logs (task_id, content, inserted_at) VALUES (?, ?, ?)",
      ["legacy-1", "", "2026-01-01 00:00:00"]
    )

    Ecto.Adapters.SQL.query!(
      repo,
      "INSERT INTO usage_records (id, run_id, task_id, source, recorded_at) VALUES (?, ?, ?, ?, ?)",
      ["use_legacy", "run_legacy", "legacy-1", "worker", 1]
    )

    Ecto.Adapters.SQL.query!(
      repo,
      "INSERT INTO task_coordination (task_id, ci_resume_count, ci_circuit_open, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?)",
      ["legacy-1", 0, 0, "2026-01-01 00:00:00", "2026-01-01 00:00:00"]
    )

    assert is_list(Ecto.Migrator.run(repo, rest, :up, all: true, log: false))

    assert [[id, board_id, external_id]] =
             Ecto.Adapters.SQL.query!(
               repo,
               "SELECT id, board_id, external_task_id FROM tasks",
               []
             ).rows

    assert id == "legacy-1"
    assert board_id == "default"
    assert external_id == "legacy-1"

    assert pk_columns(repo, "tasks") == ["id"]

    for table <- ["run_logs", "usage_records", "task_coordination"] do
      assert [["default"]] =
               Ecto.Adapters.SQL.query!(
                 repo,
                 "SELECT board_id FROM #{table}",
                 []
               ).rows
    end
  end

  test "two boards can store the same external task id" do
    assert {:ok, _} = insert_task("task-a", "board-a", "GH-1")
    assert {:ok, _} = insert_task("task-b", "board-b", "GH-1")

    assert {:error, changeset} = insert_task("task-c", "board-a", "GH-1")
    assert changeset.errors != []

    assert Repo.get(Task, "task-a").id == "task-a"
    assert Repo.get(Task, "task-b").external_task_id == "GH-1"
    assert Repo.get(Task, "task-b").board_id == "board-b"
  end

  test "kanban create keeps the generated id and copies it to external_task_id" do
    task = KanbanBridge.create_task(%{title: "Legacy insert", status: "done"})

    on_exit(fn -> Repo.delete_all(from(t in Task, where: t.id == ^task.id)) end)

    id = task.id
    assert String.starts_with?(id, "sva_")
    assert task.board_id == "default"
    assert task.external_task_id == id
    assert task.workspace_locator == nil

    assert [[^id, "default", ^id]] =
             Repo.query!(
               "SELECT id, board_id, external_task_id FROM tasks WHERE id = ?",
               [id]
             ).rows
  end

  test "a failed catalog write leaves no rows" do
    assert Store.latest_revision() == nil

    assert {:error, :unknown_harness} =
             Store.insert_revision(%{
               "providers" => [
                 %{
                   "id" => "openai",
                   "name" => "OpenAI",
                   "kind" => "openai",
                   "default_model" => "gpt-4.1"
                 }
               ],
               "boards" => [%{"id" => "alpha", "name" => "Alpha"}],
               "bindings" => [%{"board_id" => "alpha", "harness_id" => "missing"}]
             })

    assert Store.latest_revision() == nil
    assert Store.get(1) == :error
    assert catalog_counts() == %{revisions: 0, providers: 0, bindings: 0}

    assert {:ok, saved} = Store.insert_revision(valid_catalog())
    assert saved.revision == 1
    assert is_map(saved)
    refute Map.has_key?(saved, :__struct__)
    assert {:ok, ^saved} = Store.get(1)

    mise = Enum.find(saved.toolchains, &(&1.id == "elixir"))
    assert mise.source["type"] == "mise"
    assert mise.source["pins"] == [%{"name" => "elixir", "version" => "1.20.2"}]
    assert Enum.find(saved.toolchains, &(&1.id == "host")).source["type"] == "path"
    assert Enum.find(saved.toolchains, &(&1.id == "repo")).source["type"] == "repository_mise"
    assert Enum.find(saved.harnesses, &(&1.id == "pi")).adapter == "pi_rpc"
    assert Enum.map(saved.bindings, & &1.board_id) == ["alpha"]
    assert Enum.find(saved.boards, &(&1.id == "alpha")).tracker == %{"kind" => "local"}
  end

  test "no catalog revision leaves resolve and orchestrator boot on the file path" do
    assert Store.latest_revision() == nil

    base = %{kind: :local, owner: "from-file", repo: "svarm"}
    overlaid = Resolve.tracker_overlay(base)
    assert overlaid.kind in [:local, :github, :kaneo]
    refute Map.has_key?(overlaid, :catalog_revision)
    refute Map.has_key?(overlaid, :board_id)

    assert {:ok, summary} = Orchestrator.reload_config()
    {adapter, config} = Tracker.Resolve.adapter_and_config()
    assert summary.tracker_kind == (config[:kind] || :local)
    assert adapter == Tracker.Resolve.adapter_module(summary.tracker_kind)

    status = Orchestrator.status()
    assert is_integer(status.poll_interval_ms)
    refute Map.has_key?(status, :catalog_revision)
    refute Map.has_key?(status, :boards)
  end

  defp valid_catalog do
    %{
      "providers" => [
        %{
          "id" => "openai",
          "name" => "OpenAI",
          "kind" => "openai",
          "endpoint" => "https://api.openai.com",
          "credential_id" => "cred-1",
          "default_model" => "gpt-4.1"
        }
      ],
      "harnesses" => [
        %{
          "id" => "pi",
          "name" => "Pi",
          "adapter" => "pi_rpc",
          "provider_id" => "openai",
          "command" => ["pi", "--rpc"],
          "env" => %{"LANG" => "en"},
          "default_toolchain_id" => "elixir"
        }
      ],
      "toolchains" => [
        %{
          "id" => "elixir",
          "name" => "Elixir",
          "source" => %{
            "type" => "mise",
            "pins" => [%{"name" => "elixir", "version" => "1.20.2"}]
          }
        },
        %{
          "id" => "host",
          "name" => "Host",
          "source" => %{"type" => "path", "requirements" => ["mix"]}
        },
        %{
          "id" => "repo",
          "name" => "Repo",
          "source" => %{
            "type" => "repository_mise",
            "trust" => %{
              "path" => "mise.toml",
              "sha256" => String.duplicate("ab", 32),
              "trusted_by" => "operator",
              "trusted_at" => "2026-10-25T12:00:00Z"
            }
          }
        }
      ],
      "boards" => [
        %{
          "id" => "alpha",
          "name" => "Alpha",
          "tracker" => %{"kind" => "local"},
          "remote" => %{"url" => "https://example.test/alpha.git"},
          "max_concurrent" => 2,
          "verification" => %{
            "executable" => "mix",
            "args" => ["test"],
            "timeout_ms" => 60_000
          }
        }
      ],
      "bindings" => [
        %{
          "board_id" => "alpha",
          "harness_id" => "pi",
          "model_override" => "gpt-4.1-mini",
          "toolchain_id" => "elixir"
        }
      ]
    }
  end

  defp migration_modules(path) do
    path
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(fn file ->
      [version | _] = String.split(file, "_")
      {String.to_integer(version), migration_module(Path.join(path, file))}
    end)
  end

  defp migration_module(path) do
    {:ok, body} = File.read(path)
    [_, name] = Regex.run(~r/defmodule (Svarm\.Repo\.Migrations\.\w+)/, body)
    String.to_existing_atom("Elixir." <> name)
  end

  defp insert_task(id, board_id, external_task_id) do
    %Task{id: id, created_at: 1}
    |> Task.changeset(%{
      title: "identity",
      status: "done",
      board_id: board_id,
      external_task_id: external_task_id
    })
    |> Repo.insert()
  end

  defp clear_catalog do
    for table <- [
          "catalog_board_bindings",
          "catalog_boards",
          "catalog_harness_profiles",
          "catalog_toolchain_profiles",
          "catalog_provider_profiles",
          "catalog_revisions"
        ] do
      Repo.query!("DELETE FROM #{table}")
    end

    Repo.delete_all(from(t in Task, where: t.title in ["identity", "Legacy insert"]))
  end

  defp catalog_counts do
    %{
      revisions: count("catalog_revisions"),
      providers: count("catalog_provider_profiles"),
      bindings: count("catalog_board_bindings")
    }
  end

  defp count(table) do
    [[n]] = Repo.query!("SELECT COUNT(*) FROM #{table}").rows
    n
  end

  defp pk_columns(repo, table) do
    Ecto.Adapters.SQL.query!(repo, "PRAGMA table_info(#{table})", []).rows
    |> Enum.filter(fn [_cid, _name, _type, _notnull, _default, pk] -> pk == 1 end)
    |> Enum.map(fn [_cid, name, _type, _notnull, _default, _pk] -> name end)
  end

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :svarm,
      adapter: Ecto.Adapters.SQLite3
  end
end
